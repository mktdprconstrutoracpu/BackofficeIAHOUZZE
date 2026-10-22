-- 004 (22/10/2026): atendimento humano, etiquetas, ficha do lead, avisos, painel, nao resolvidas, agenda e papeis.
-- Rodar UMA vez no SQL Editor do Supabase, depois do 001, 002 e 003. Pode rodar de novo sem estragar.
--
-- O que entra:
--   1. papeis em ia_liberacoes (gerente ve tudo; corretor ve as conversas dele e as sem dono)
--   2. estado da conversa em ia_conversas: Ana pausada, etiqueta (manual e automatica), notas, corretor responsavel
--   3. mensagens do corretor em ia_mensagens (direcao 'corretor')
--   4. ia_envios: a fila do que o corretor manda pelo backoffice (o n8n envia pela Meta e grava no historico)
--   5. ia_eventos: o que dispara aviso ou sincronizacao (novo lead, pediu humano, visita confirmada/remarcada/cancelada)
--   6. ia_agendamentos: status do corretor, visita remarcada, quem mexeu
--   7. visoes: ia_conversas_v (lista com etiqueta efetiva e lead), ia_metricas_dia, ia_metricas_hora, ia_nao_resolvidas
--   8. RLS por papel e permissao de escrita so nas colunas certas
--   9. tempo real em ia_conversas e ia_envios
--  10. liberacao do gerente

-- ============================================================ 1. papeis
alter table public.ia_liberacoes add column if not exists papel text not null default 'corretor';
alter table public.ia_liberacoes drop constraint if exists ia_liberacoes_papel_check;
alter table public.ia_liberacoes add constraint ia_liberacoes_papel_check check (papel in ('gerente', 'corretor'));
alter table public.ia_liberacoes add column if not exists whatsapp text;  -- numero do corretor para avisos (so digitos), opcional

create or replace function public.ia_email() returns text
language sql stable as $$ select lower(coalesce(auth.jwt() ->> 'email', '')) $$;

create or replace function public.ia_papel() returns text
language sql stable security definer set search_path = public as $$
  select l.papel from public.ia_liberacoes l where lower(l.email) = public.ia_email() limit 1
$$;

-- (a funcao ia_ve_conversa esta logo depois da parte 2: ela le corretor_email, que e criada la,
--  e o Postgres confere o corpo de uma funcao em SQL na hora de criar)

-- ============================================================ 2. estado da conversa
alter table public.ia_conversas
  add column if not exists pausada            boolean not null default false,  -- Ana fora; o corretor responde
  add column if not exists pausada_em         timestamptz,
  add column if not exists pausada_por        text,
  add column if not exists etiqueta           text,          -- escolhida pela equipe; vence a automatica
  add column if not exists etiqueta_auto      text,          -- calculada pelo banco a cada mensagem
  add column if not exists notas              text,
  add column if not exists corretor_email     text,          -- quem assumiu a conversa
  add column if not exists primeira_cliente_em timestamptz,
  add column if not exists primeira_ana_em    timestamptz,
  add column if not exists pediu_humano_em    timestamptz,
  add column if not exists perguntou_preco_em timestamptz,
  add column if not exists ultima_corretor_em timestamptz;

alter table public.ia_conversas drop constraint if exists ia_conversas_etiqueta_check;
alter table public.ia_conversas add constraint ia_conversas_etiqueta_check
  check (etiqueta is null or etiqueta in ('novo', 'quente', 'morno', 'frio', 'agendado', 'perdido', 'pediu humano', 'fechado'));

-- gerente ve tudo; corretor ve as conversas sem dono e as que assumiu
-- (fica depois das colunas novas de ia_conversas: a 1a versao deste arquivo a criava na parte 1 e caia em
--  "column c.corretor_email does not exist", porque o corpo de funcao em SQL e conferido na criacao)
create or replace function public.ia_ve_conversa(p_telefone text) returns boolean
language sql stable security definer set search_path = public as $$
  select case
    when not public.ia_tem_acesso() then false
    when public.ia_papel() = 'gerente' then true
    else exists (
      select 1 from public.ia_conversas c
      where c.telefone = p_telefone
        and (c.corretor_email is null or lower(c.corretor_email) = public.ia_email())
    )
  end
$$;

-- ============================================================ 3. mensagens do corretor
alter table public.ia_mensagens drop constraint if exists ia_mensagens_direcao_check;
alter table public.ia_mensagens add constraint ia_mensagens_direcao_check check (direcao in ('cliente', 'ana', 'corretor'));
alter table public.ia_mensagens add column if not exists autor_email text;  -- quem escreveu, quando direcao = corretor

-- (as colunas novas da agenda entram aqui porque a funcao abaixo ja le status_corretor)
alter table public.ia_agendamentos
  add column if not exists status_corretor text,
  add column if not exists observacao      text,
  add column if not exists atualizado_por  text,
  add column if not exists sincronizado_em timestamptz;

-- etiqueta automatica: a partir do que ja aconteceu na conversa
create or replace function public.ia_calcular_etiqueta(c public.ia_conversas) returns text
language sql stable as $$
  select case
    when exists (select 1 from public.ia_agendamentos a where a.telefone = c.telefone and a.visita_dia is not null
                 and coalesce(a.status_corretor, '') not ilike '%cancel%') then 'agendado'
    when c.pediu_humano_em is not null then 'pediu humano'
    when c.perguntou_preco_em is not null and c.do_cliente >= 3 then 'quente'
    when c.do_cliente >= 2 then 'morno'
    else 'novo'
  end
$$;

-- o gatilho de toda mensagem nova (versao 3: primeira resposta, sinais do cliente, corretor e etiqueta)
create or replace function public.ia_atualizar_conversa() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_humano boolean := new.direcao = 'cliente' and new.texto ~* '(atendente|humano|pessoa de verdade|falar com (um |uma |o |a )?(corretor|alguém|alguem|pessoa|gente)|quero um corretor|robô|robo)';
  v_preco  boolean := new.direcao = 'cliente' and new.texto ~* '(pre[çc]o|quanto (custa|é|e|fica|sai)|valor|parcela|financi|entrada|visita|agendar|conhecer)';
  v_c public.ia_conversas;
begin
  insert into public.ia_conversas
    (telefone, nome_whatsapp, primeira_em, ultima_em, ultima_mensagem, ultima_direcao, ultima_tipo, ultima_cliente_em, total, do_cliente,
     primeira_cliente_em, primeira_ana_em, pediu_humano_em, perguntou_preco_em, ultima_corretor_em, pausada, pausada_em, pausada_por)
  values
    (new.telefone, nullif(new.nome_whatsapp, ''), new.criada_em, new.criada_em, left(new.texto, 200), new.direcao, new.tipo,
     case when new.direcao = 'cliente' then new.criada_em end,
     1, case when new.direcao = 'cliente' then 1 else 0 end,
     case when new.direcao = 'cliente' then new.criada_em end,
     case when new.direcao = 'ana' then new.criada_em end,
     case when v_humano then new.criada_em end,
     case when v_preco then new.criada_em end,
     case when new.direcao = 'corretor' then new.criada_em end,
     new.direcao = 'corretor', case when new.direcao = 'corretor' then new.criada_em end, case when new.direcao = 'corretor' then new.autor_email end)
  on conflict (telefone) do update set
    nome_whatsapp       = coalesce(nullif(excluded.nome_whatsapp, ''), ia_conversas.nome_whatsapp),
    ultima_em           = greatest(ia_conversas.ultima_em, excluded.ultima_em),
    ultima_mensagem     = case when excluded.ultima_em >= ia_conversas.ultima_em then excluded.ultima_mensagem else ia_conversas.ultima_mensagem end,
    ultima_direcao      = case when excluded.ultima_em >= ia_conversas.ultima_em then excluded.ultima_direcao  else ia_conversas.ultima_direcao  end,
    ultima_tipo         = case when excluded.ultima_em >= ia_conversas.ultima_em then excluded.ultima_tipo     else ia_conversas.ultima_tipo     end,
    ultima_cliente_em   = greatest(ia_conversas.ultima_cliente_em, excluded.ultima_cliente_em),
    total               = ia_conversas.total + 1,
    do_cliente          = ia_conversas.do_cliente + excluded.do_cliente,
    primeira_cliente_em = least(ia_conversas.primeira_cliente_em, excluded.primeira_cliente_em),
    primeira_ana_em     = least(ia_conversas.primeira_ana_em, excluded.primeira_ana_em),
    pediu_humano_em     = coalesce(ia_conversas.pediu_humano_em, excluded.pediu_humano_em),
    perguntou_preco_em  = coalesce(ia_conversas.perguntou_preco_em, excluded.perguntou_preco_em),
    ultima_corretor_em  = greatest(ia_conversas.ultima_corretor_em, excluded.ultima_corretor_em),
    -- mensagem do corretor = a Ana sai de cena ate alguem retomar
    pausada             = ia_conversas.pausada or excluded.pausada,
    pausada_em          = case when excluded.pausada and not ia_conversas.pausada then excluded.pausada_em else ia_conversas.pausada_em end,
    pausada_por         = case when excluded.pausada and not ia_conversas.pausada then excluded.pausada_por else ia_conversas.pausada_por end,
    corretor_email      = coalesce(ia_conversas.corretor_email, case when new.direcao = 'corretor' then new.autor_email end)
  returning * into v_c;

  update public.ia_conversas set etiqueta_auto = public.ia_calcular_etiqueta(v_c) where telefone = new.telefone;
  return new;
end $$;

-- preenche as colunas novas para o que ja existe
update public.ia_conversas c set
  primeira_cliente_em = (select min(m.criada_em) from public.ia_mensagens m where m.telefone = c.telefone and m.direcao = 'cliente'),
  primeira_ana_em     = (select min(m.criada_em) from public.ia_mensagens m where m.telefone = c.telefone and m.direcao = 'ana'),
  pediu_humano_em     = (select min(m.criada_em) from public.ia_mensagens m where m.telefone = c.telefone and m.direcao = 'cliente'
                          and m.texto ~* '(atendente|humano|pessoa de verdade|falar com (um |uma |o |a )?(corretor|alguém|alguem|pessoa|gente)|quero um corretor|robô|robo)'),
  perguntou_preco_em  = (select min(m.criada_em) from public.ia_mensagens m where m.telefone = c.telefone and m.direcao = 'cliente'
                          and m.texto ~* '(pre[çc]o|quanto (custa|é|e|fica|sai)|valor|parcela|financi|entrada|visita|agendar|conhecer)');

-- ============================================================ 4. fila de envios do corretor
create table if not exists public.ia_envios (
  id          bigint generated always as identity primary key,
  telefone    text not null,
  texto       text not null,
  por_email   text not null,                 -- quem mandou (e-mail do login)
  por_nome    text,
  status      text not null default 'pendente' check (status in ('pendente', 'enviado', 'erro')),
  erro        text,
  wa_id       text,
  criado_em   timestamptz not null default now(),
  enviado_em  timestamptz
);
create index if not exists ia_envios_telefone on public.ia_envios (telefone, criado_em);

-- ============================================================ 5. eventos (avisos e sincronizacao)
create table if not exists public.ia_eventos (
  id         bigint generated always as identity primary key,
  tipo       text not null,       -- novo_agendamento | pediu_humano | agendamento_atualizado
  telefone   text,
  dados      jsonb not null default '{}'::jsonb,
  criado_em  timestamptz not null default now(),
  tratado_em timestamptz,
  resultado  text
);

-- ============================================================ 6. agenda
-- (as colunas status_corretor, observacao, atualizado_por e sincronizado_em foram criadas na parte 3)
-- status_corretor: confirmada | remarcada | cancelada | realizada (mexido pelo backoffice)
-- sincronizado_em: quando o n8n devolveu a mudanca para a planilha

-- a sincronizacao da planilha (chave de servico, a cada 5 min) nao desfaz o que a equipe mexeu pelo backoffice:
-- depois que alguem confirma, remarca ou cancela por aqui, o backoffice manda nesse lead e a planilha recebe
create or replace function public.ia_agendamento_protege() returns trigger
language plpgsql as $$
begin
  if coalesce(auth.role(), '') <> 'authenticated' and old.atualizado_por is not null then
    new.visita_dia      := old.visita_dia;
    new.visita_periodo  := old.visita_periodo;
    new.status_corretor := old.status_corretor;
    new.observacao      := old.observacao;
    new.atualizado_por  := old.atualizado_por;
  end if;
  return new;
end $$;
drop trigger if exists ia_agendamentos_protege on public.ia_agendamentos;
create trigger ia_agendamentos_protege before update on public.ia_agendamentos
  for each row execute function public.ia_agendamento_protege();

-- novo lead -> evento (aviso ao corretor) e a conversa ganha a etiqueta "agendado"
create or replace function public.ia_agendamento_inserido() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.ia_eventos (tipo, telefone, dados)
  values ('novo_agendamento', new.telefone, jsonb_build_object(
    'chave', new.chave, 'nome', new.nome, 'telefone', new.telefone, 'interesse', new.interesse,
    'unidade', new.unidade_interesse, 'visita_dia', new.visita_dia, 'visita_periodo', new.visita_periodo,
    'resumo', new.resumo, 'data_hora_texto', new.data_hora_texto));
  update public.ia_conversas c set etiqueta_auto = public.ia_calcular_etiqueta(c) where c.telefone = new.telefone;
  return new;
end $$;
drop trigger if exists ia_agendamentos_inserido on public.ia_agendamentos;
create trigger ia_agendamentos_inserido after insert on public.ia_agendamentos
  for each row execute function public.ia_agendamento_inserido();

-- visita mexida pelo backoffice -> evento (o n8n devolve para a planilha)
create or replace function public.ia_agendamento_mexido() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.atualizado_por is not null and (
       coalesce(new.status_corretor, '') is distinct from coalesce(old.status_corretor, '')
    or new.visita_dia is distinct from old.visita_dia
    or coalesce(new.visita_periodo, '') is distinct from coalesce(old.visita_periodo, '')
    or coalesce(new.observacao, '') is distinct from coalesce(old.observacao, '')) then
    insert into public.ia_eventos (tipo, telefone, dados)
    values ('agendamento_atualizado', new.telefone, jsonb_build_object(
      'chave', new.chave, 'data_hora_texto', new.data_hora_texto, 'telefone', new.telefone, 'nome', new.nome,
      'status_corretor', new.status_corretor, 'visita_dia', new.visita_dia, 'visita_periodo', new.visita_periodo,
      'observacao', new.observacao, 'atualizado_por', new.atualizado_por));
    update public.ia_conversas c set etiqueta_auto = public.ia_calcular_etiqueta(c) where c.telefone = new.telefone;
  end if;
  return new;
end $$;
drop trigger if exists ia_agendamentos_mexido on public.ia_agendamentos;
create trigger ia_agendamentos_mexido after update on public.ia_agendamentos
  for each row execute function public.ia_agendamento_mexido();

-- cliente pediu humano -> evento (aviso ao corretor), uma vez por conversa
-- (insert tambem: o pedido pode vir logo na primeira mensagem, quando a conversa ainda nao existia)
create or replace function public.ia_conversa_pediu_humano() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.pediu_humano_em is not null and (tg_op = 'INSERT' or old.pediu_humano_em is null) then
    insert into public.ia_eventos (tipo, telefone, dados)
    values ('pediu_humano', new.telefone, jsonb_build_object('nome', new.nome_whatsapp, 'telefone', new.telefone, 'ultima_mensagem', new.ultima_mensagem));
  end if;
  return new;
end $$;
drop trigger if exists ia_conversas_pediu_humano on public.ia_conversas;
create trigger ia_conversas_pediu_humano after insert or update on public.ia_conversas
  for each row execute function public.ia_conversa_pediu_humano();

-- ============================================================ 7. visoes
-- a lista do backoffice: a conversa com a etiqueta efetiva (manual > automatica > tempo) e o lead mais recente
create or replace view public.ia_conversas_v with (security_invoker = true) as
select c.*,
       coalesce(c.etiqueta,
         case
           when c.etiqueta_auto in ('agendado', 'pediu humano') then c.etiqueta_auto
           when c.ultima_em < now() - interval '7 days' then 'perdido'
           when c.ultima_em < now() - interval '24 hours' and c.ultima_direcao <> 'cliente' then 'frio'
           else coalesce(c.etiqueta_auto, 'novo')
         end) as etiqueta_efetiva,
       a.chave as lead_chave, a.interesse as lead_interesse, a.renda_informada as lead_renda, a.unidade_interesse as lead_unidade,
       a.visita_dia as lead_visita_dia, a.visita_periodo as lead_visita_periodo, a.status as lead_status,
       a.status_corretor as lead_status_corretor, a.resumo as lead_resumo, a.data_hora_texto as lead_registrado
from public.ia_conversas c
left join lateral (
  select * from public.ia_agendamentos a where a.telefone = c.telefone order by a.registrado_em desc nulls last limit 1
) a on true;

-- metricas por dia (ultimos 90 dias), para o painel
create or replace view public.ia_metricas_dia with (security_invoker = true) as
with dias as (
  select generate_series((now() at time zone 'America/Sao_Paulo')::date - 89, (now() at time zone 'America/Sao_Paulo')::date, '1 day')::date as dia
),
conv as (
  select (primeira_em at time zone 'America/Sao_Paulo')::date as dia,
         count(*) as conversas,
         count(*) filter (where pediu_humano_em is not null) as pediram_humano,
         avg(extract(epoch from (primeira_ana_em - primeira_cliente_em))) filter (where primeira_ana_em > primeira_cliente_em) as resposta_media_s
  from public.ia_conversas group by 1
),
msgs as (
  select (criada_em at time zone 'America/Sao_Paulo')::date as dia,
         count(*) filter (where direcao = 'cliente') as msgs_cliente,
         count(*) filter (where direcao = 'ana') as msgs_ana,
         count(*) filter (where direcao = 'corretor') as msgs_corretor
  from public.ia_mensagens group by 1
),
leads as (
  select (registrado_em at time zone 'America/Sao_Paulo')::date as dia,
         count(*) as leads,
         count(*) filter (where visita_dia is not null) as visitas
  from public.ia_agendamentos where registrado_em is not null group by 1
)
select d.dia,
       coalesce(c.conversas, 0) as conversas, coalesce(c.pediram_humano, 0) as pediram_humano, c.resposta_media_s,
       coalesce(m.msgs_cliente, 0) as msgs_cliente, coalesce(m.msgs_ana, 0) as msgs_ana, coalesce(m.msgs_corretor, 0) as msgs_corretor,
       coalesce(l.leads, 0) as leads, coalesce(l.visitas, 0) as visitas
from dias d
left join conv c on c.dia = d.dia
left join msgs m on m.dia = d.dia
left join leads l on l.dia = d.dia
order by d.dia;

-- horario de pico: mensagens do cliente por hora do dia (ultimos 30 dias)
create or replace view public.ia_metricas_hora with (security_invoker = true) as
select h.hora, coalesce(x.mensagens, 0) as mensagens
from generate_series(0, 23) as h(hora)
left join (
  select extract(hour from criada_em at time zone 'America/Sao_Paulo')::int as hora, count(*) as mensagens
  from public.ia_mensagens where direcao = 'cliente' and criada_em > now() - interval '30 days' group by 1
) x on x.hora = h.hora
order by h.hora;

-- conversas que a Ana nao resolveu: a fila para melhorar o prompt (e para o corretor agir)
create or replace view public.ia_nao_resolvidas with (security_invoker = true) as
select c.telefone, c.nome_whatsapp, c.ultima_em, c.ultima_mensagem, c.ultima_direcao, c.pausada, c.corretor_email,
       case
         when c.pediu_humano_em is not null and (c.ultima_corretor_em is null or c.ultima_corretor_em < c.pediu_humano_em) then 'pediu humano'
         when exists (select 1 from public.ia_mensagens m where m.telefone = c.telefone and m.direcao = 'ana'
                      and m.texto ~* '(não sei|nao sei|não tenho (essa|esta) informa|vou confirmar com o corretor|não consigo (ver|acessar))') then 'ana sem resposta'
         when c.perguntou_preco_em is not null and c.ultima_direcao = 'ana' and c.ultima_em < now() - interval '2 hours'
              and not exists (select 1 from public.ia_agendamentos a where a.telefone = c.telefone) then 'sumiu depois do preço'
       end as motivo
from public.ia_conversas c
where c.ultima_em > now() - interval '30 days'
  and (
    (c.pediu_humano_em is not null and (c.ultima_corretor_em is null or c.ultima_corretor_em < c.pediu_humano_em))
    or exists (select 1 from public.ia_mensagens m where m.telefone = c.telefone and m.direcao = 'ana'
               and m.texto ~* '(não sei|nao sei|não tenho (essa|esta) informa|vou confirmar com o corretor|não consigo (ver|acessar))')
    or (c.perguntou_preco_em is not null and c.ultima_direcao = 'ana' and c.ultima_em < now() - interval '2 hours'
        and not exists (select 1 from public.ia_agendamentos a where a.telefone = c.telefone))
  )
order by c.ultima_em desc;

-- ============================================================ 8. RLS por papel
alter table public.ia_envios  enable row level security;
alter table public.ia_eventos enable row level security;

-- leitura
drop policy if exists ia_mensagens_ler on public.ia_mensagens;
create policy ia_mensagens_ler on public.ia_mensagens for select to authenticated using (public.ia_ve_conversa(telefone));
drop policy if exists ia_conversas_ler on public.ia_conversas;
create policy ia_conversas_ler on public.ia_conversas for select to authenticated
  using (public.ia_tem_acesso() and (public.ia_papel() = 'gerente' or corretor_email is null or lower(corretor_email) = public.ia_email()));
drop policy if exists ia_agendamentos_ler on public.ia_agendamentos;
create policy ia_agendamentos_ler on public.ia_agendamentos for select to authenticated
  using (public.ia_tem_acesso() and (public.ia_papel() = 'gerente' or public.ia_ve_conversa(telefone)));
drop policy if exists ia_envios_ler on public.ia_envios;
create policy ia_envios_ler on public.ia_envios for select to authenticated using (public.ia_ve_conversa(telefone));
drop policy if exists ia_liberacoes_ler on public.ia_liberacoes;
create policy ia_liberacoes_ler on public.ia_liberacoes for select to authenticated
  using (lower(email) = public.ia_email() or public.ia_papel() = 'gerente');
-- ia_eventos: so o n8n (chave de servico); o site nao le

-- escrita: so as colunas certas, so quem ve a conversa
revoke update on public.ia_conversas from authenticated, anon;
grant update (etiqueta, notas, pausada, pausada_em, pausada_por, corretor_email) on public.ia_conversas to authenticated;
drop policy if exists ia_conversas_mexer on public.ia_conversas;
create policy ia_conversas_mexer on public.ia_conversas for update to authenticated
  using (public.ia_ve_conversa(telefone)) with check (public.ia_ve_conversa(telefone));

revoke update on public.ia_agendamentos from authenticated, anon;
grant update (status_corretor, observacao, visita_dia, visita_periodo, atualizado_por) on public.ia_agendamentos to authenticated;
drop policy if exists ia_agendamentos_mexer on public.ia_agendamentos;
create policy ia_agendamentos_mexer on public.ia_agendamentos for update to authenticated
  using (public.ia_tem_acesso() and (public.ia_papel() = 'gerente' or public.ia_ve_conversa(telefone)))
  with check (public.ia_tem_acesso());

revoke insert on public.ia_envios from anon;
drop policy if exists ia_envios_enviar on public.ia_envios;
create policy ia_envios_enviar on public.ia_envios for insert to authenticated
  with check (public.ia_ve_conversa(telefone) and lower(por_email) = public.ia_email() and length(texto) between 1 and 4000);

-- ============================================================ 9. tempo real
do $$ begin alter publication supabase_realtime add table public.ia_conversas; exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.ia_envios;    exception when duplicate_object then null; end $$;
-- o UPDATE em tempo real precisa da linha inteira
alter table public.ia_conversas replica identity full;
alter table public.ia_envios replica identity full;

-- ============================================================ 10. quem entra
-- O usuario precisa existir em Authentication > Users (Add user, com Auto Confirm). Aqui so a liberacao e o papel.
insert into public.ia_liberacoes (email, nome, papel) values ('lucas@hotmail.com', 'Lucas', 'gerente')
  on conflict (email) do update set papel = 'gerente', nome = coalesce(ia_liberacoes.nome, excluded.nome);
update public.ia_liberacoes set papel = 'gerente' where lower(email) = 'imobiliariahouzze@gmail.com';
-- corretores: insert into public.ia_liberacoes (email, nome, papel, whatsapp) values ('corretor@houzze.com.br', 'Nome', 'corretor', '5511999999999');
