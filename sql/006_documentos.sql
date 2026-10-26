-- 006_documentos.sql (26/10/2026): documentos do cliente antes do agendamento.
-- A Ana pede CNH ou RG, comprovante de residencia, imposto de renda, certidao de nascimento, comprovante de renda
-- formal e extrato bancario dos ultimos 6 meses. A pessoa manda foto ou PDF pelo WhatsApp; o n8n baixa da Meta, guarda
-- no cofre privado "documentos" (Storage) e registra aqui; o backoffice mostra, abre, reclassifica e marca conferido.
-- Rodar no SQL Editor do projeto Central depois do 005. Pode rodar mais de uma vez.

-- 1. cofre de arquivos privado -----------------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('documentos', 'documentos', false, 20971520, array['image/jpeg','image/png','image/webp','application/pdf'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

-- 2. tabela ----------------------------------------------------------------------------------------------------------
create table if not exists public.ia_documentos (
  id             bigserial primary key,
  telefone       text        not null,
  tipo           text        not null default 'outro'
                 check (tipo in ('cnh_rg','comprovante_residencia','imposto_renda','certidao_nascimento','renda','extrato','outro')),
  arquivo        text        not null,                 -- caminho dentro do cofre documentos: <telefone>/<timestamp>-<tipo>.<ext>
  mime           text,
  nome_original  text,
  legenda        text,                                 -- o que a pessoa escreveu junto com o arquivo
  wa_id          text        unique,                   -- id da mensagem no WhatsApp (nao grava o mesmo arquivo duas vezes)
  recebido_em    timestamptz not null default now(),
  status         text        not null default 'recebido' check (status in ('recebido','conferido','recusado')),
  conferido_por  text,
  conferido_em   timestamptz,
  observacao     text
);
create index if not exists ia_documentos_telefone_idx on public.ia_documentos (telefone, recebido_em desc);

-- a conversa guarda qual documento a Ana pediu por ultimo (para rotular o proximo arquivo que chegar)
alter table public.ia_conversas add column if not exists documento_esperado   text;
alter table public.ia_conversas add column if not exists documentos_pedidos_em timestamptz;

-- 3. quem ve e quem mexe ---------------------------------------------------------------------------------------------
alter table public.ia_documentos enable row level security;
drop policy if exists ia_documentos_leitura on public.ia_documentos;
create policy ia_documentos_leitura on public.ia_documentos
  for select to authenticated using (public.ia_tem_acesso());
drop policy if exists ia_documentos_atendimento on public.ia_documentos;
create policy ia_documentos_atendimento on public.ia_documentos
  for update to authenticated using (public.ia_tem_acesso()) with check (public.ia_tem_acesso());
grant select on public.ia_documentos to authenticated;
grant update (tipo, status, conferido_por, conferido_em, observacao) on public.ia_documentos to authenticated;
-- o n8n grava com a chave de servico (passa por cima do RLS); ninguem logado insere ou apaga

-- arquivos: a equipe liberada le (o backoffice gera um link assinado); so a chave de servico grava
drop policy if exists documentos_leitura_equipe on storage.objects;
create policy documentos_leitura_equipe on storage.objects
  for select to authenticated using (bucket_id = 'documentos' and public.ia_tem_acesso());

-- 4. resumo por telefone (o backoffice e a Ana usam) ----------------------------------------------------------------
create or replace view public.ia_documentos_resumo with (security_invoker = true) as
select
  d.telefone,
  count(*)                                                        as arquivos,
  count(distinct d.tipo) filter (where d.tipo <> 'outro')         as tipos_recebidos,
  array_agg(distinct d.tipo) filter (where d.tipo <> 'outro')     as tipos,
  count(*) filter (where d.tipo = 'outro')                        as sem_tipo,
  count(*) filter (where d.status = 'conferido')                  as conferidos,
  max(d.recebido_em)                                              as ultimo_em
from public.ia_documentos d
group by d.telefone;
grant select on public.ia_documentos_resumo to authenticated;

-- lista fixa dos seis, na ordem em que a Ana pede (o backoffice e o n8n leem daqui para nao duplicar a lista)
create or replace function public.ia_documentos_exigidos()
returns table (tipo text, nome text, ordem int)
language sql immutable as $$
  values ('cnh_rg', 'CNH ou RG', 1),
         ('comprovante_residencia', 'Comprovante de residência', 2),
         ('imposto_renda', 'Declaração de imposto de renda', 3),
         ('certidao_nascimento', 'Certidão de nascimento ou casamento', 4),
         ('renda', 'Comprovante de renda formal', 5),
         ('extrato', 'Extrato bancário dos últimos 6 meses', 6)
$$;
grant execute on function public.ia_documentos_exigidos() to authenticated, anon, service_role;

-- o que falta para um telefone (texto pronto para a Ana e para a resposta automatica do n8n)
create or replace function public.ia_documentos_faltando(p_telefone text)
returns text
language sql stable as $$
  select coalesce(string_agg(e.nome, ', ' order by e.ordem), '')
  from public.ia_documentos_exigidos() e
  where not exists (
    select 1 from public.ia_documentos d
    where d.tipo = e.tipo and right(d.telefone, 11) = right(p_telefone, 11)
  )
$$;
grant execute on function public.ia_documentos_faltando(text) to authenticated, service_role;

-- 5. a Ana reclassifica o ultimo arquivo "outro" quando a pessoa diz o que era ------------------------------------
create or replace function public.ia_classificar_ultimo_documento(p_telefone text, p_tipo text)
returns boolean
language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  if p_tipo not in ('cnh_rg','comprovante_residencia','imposto_renda','certidao_nascimento','renda','extrato') then
    return false;
  end if;
  select id into v_id from public.ia_documentos
   where right(telefone, 11) = right(p_telefone, 11) and tipo = 'outro'
   order by recebido_em desc limit 1;
  if v_id is null then return false; end if;
  update public.ia_documentos set tipo = p_tipo where id = v_id;
  return true;
end $$;
revoke all on function public.ia_classificar_ultimo_documento(text, text) from public, anon, authenticated;
grant execute on function public.ia_classificar_ultimo_documento(text, text) to service_role;

-- 6. a conversa fica sabendo (ultima mensagem e etiqueta) e o painel ganha tempo real ----------------------------
create or replace function public.ia_documento_inserido()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.ia_conversas
     set documento_esperado = null
   where right(telefone, 11) = right(new.telefone, 11);
  return new;
end $$;
drop trigger if exists ia_documento_inserido on public.ia_documentos;
create trigger ia_documento_inserido after insert on public.ia_documentos
  for each row execute function public.ia_documento_inserido();

do $$ begin
  alter publication supabase_realtime add table public.ia_documentos;
exception when duplicate_object then null; end $$;
alter table public.ia_documentos replica identity full;
