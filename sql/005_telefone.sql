-- 005 (22/10/2026): lead e conversa casam pelos ultimos 11 digitos do telefone.
-- A planilha de leads grava o telefone como a Ana escreve (ex.: 11959943705, sem o 55) e o WhatsApp manda com o
-- DDI (5511959943705). Com a comparacao exata do 004, a ficha do lead ficava vazia e a etiqueta "agendado" nao
-- acendia. Rodar UMA vez no SQL Editor, depois do 004. Pode rodar de novo sem estragar.

-- os ultimos 11 digitos (DDD + numero), sem nada que nao seja digito
create or replace function public.ia_tel11(t text) returns text
language sql immutable as $$ select right(regexp_replace(coalesce(t, ''), '\D', '', 'g'), 11) $$;

-- quem ve um lead: gerente tudo; corretor, os leads cuja conversa nao e de outro corretor (ou que nem tem conversa)
create or replace function public.ia_ve_agendamento(p_telefone text) returns boolean
language sql stable security definer set search_path = public as $$
  select case
    when not public.ia_tem_acesso() then false
    when public.ia_papel() = 'gerente' then true
    else not exists (
      select 1 from public.ia_conversas c
      where public.ia_tel11(c.telefone) = public.ia_tel11(p_telefone)
        and c.corretor_email is not null and lower(c.corretor_email) <> public.ia_email()
    )
  end
$$;

-- etiqueta automatica: "agendado" quando ha visita para o mesmo numero
create or replace function public.ia_calcular_etiqueta(c public.ia_conversas) returns text
language sql stable as $$
  select case
    when exists (select 1 from public.ia_agendamentos a
                 where public.ia_tel11(a.telefone) = public.ia_tel11(c.telefone) and a.visita_dia is not null
                   and coalesce(a.status_corretor, '') not ilike '%cancel%') then 'agendado'
    when c.pediu_humano_em is not null then 'pediu humano'
    when c.perguntou_preco_em is not null and c.do_cliente >= 3 then 'quente'
    when c.do_cliente >= 2 then 'morno'
    else 'novo'
  end
$$;

-- os gatilhos da agenda recalculam a etiqueta da conversa do mesmo numero
create or replace function public.ia_agendamento_inserido() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.ia_eventos (tipo, telefone, dados)
  values ('novo_agendamento', new.telefone, jsonb_build_object(
    'chave', new.chave, 'nome', new.nome, 'telefone', new.telefone, 'interesse', new.interesse,
    'unidade', new.unidade_interesse, 'visita_dia', new.visita_dia, 'visita_periodo', new.visita_periodo,
    'resumo', new.resumo, 'data_hora_texto', new.data_hora_texto));
  update public.ia_conversas c set etiqueta_auto = public.ia_calcular_etiqueta(c)
    where public.ia_tel11(c.telefone) = public.ia_tel11(new.telefone);
  return new;
end $$;

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
    update public.ia_conversas c set etiqueta_auto = public.ia_calcular_etiqueta(c)
      where public.ia_tel11(c.telefone) = public.ia_tel11(new.telefone);
  end if;
  return new;
end $$;

-- a lista do backoffice: o lead mais recente do mesmo numero
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
  select * from public.ia_agendamentos a
  where public.ia_tel11(a.telefone) = public.ia_tel11(c.telefone)
  order by a.registrado_em desc nulls last limit 1
) a on true;

-- nao resolvidas: "sumiu depois do preco" so quando nao ha lead do mesmo numero
create or replace view public.ia_nao_resolvidas with (security_invoker = true) as
select c.telefone, c.nome_whatsapp, c.ultima_em, c.ultima_mensagem, c.ultima_direcao, c.pausada, c.corretor_email,
       case
         when c.pediu_humano_em is not null and (c.ultima_corretor_em is null or c.ultima_corretor_em < c.pediu_humano_em) then 'pediu humano'
         when exists (select 1 from public.ia_mensagens m where m.telefone = c.telefone and m.direcao = 'ana'
                      and m.texto ~* '(não sei|nao sei|não tenho (essa|esta) informa|vou confirmar com o corretor|não consigo (ver|acessar))') then 'ana sem resposta'
         when c.perguntou_preco_em is not null and c.ultima_direcao = 'ana' and c.ultima_em < now() - interval '2 hours'
              and not exists (select 1 from public.ia_agendamentos a where public.ia_tel11(a.telefone) = public.ia_tel11(c.telefone)) then 'sumiu depois do preço'
       end as motivo
from public.ia_conversas c
where c.ultima_em > now() - interval '30 days'
  and (
    (c.pediu_humano_em is not null and (c.ultima_corretor_em is null or c.ultima_corretor_em < c.pediu_humano_em))
    or exists (select 1 from public.ia_mensagens m where m.telefone = c.telefone and m.direcao = 'ana'
               and m.texto ~* '(não sei|nao sei|não tenho (essa|esta) informa|vou confirmar com o corretor|não consigo (ver|acessar))')
    or (c.perguntou_preco_em is not null and c.ultima_direcao = 'ana' and c.ultima_em < now() - interval '2 hours'
        and not exists (select 1 from public.ia_agendamentos a where public.ia_tel11(a.telefone) = public.ia_tel11(c.telefone)))
  )
order by c.ultima_em desc;

-- quem le e quem mexe na agenda
drop policy if exists ia_agendamentos_ler on public.ia_agendamentos;
create policy ia_agendamentos_ler on public.ia_agendamentos for select to authenticated
  using (public.ia_ve_agendamento(telefone));
drop policy if exists ia_agendamentos_mexer on public.ia_agendamentos;
create policy ia_agendamentos_mexer on public.ia_agendamentos for update to authenticated
  using (public.ia_ve_agendamento(telefone)) with check (public.ia_tem_acesso());

-- recalcula a etiqueta automatica de todo mundo com a comparacao nova
update public.ia_conversas c set etiqueta_auto = public.ia_calcular_etiqueta(c);
