-- 002 (20/10/2026): retomada automatica da Ana.
-- Rodar UMA vez no SQL Editor do Supabase, depois do 001. Pode rodar de novo sem estragar.
--
-- Regra: se a ultima mensagem da conversa e da Ana (texto normal) e o cliente ficou 20 minutos sem responder,
-- o n8n manda uma retomada ("posso ajudar em mais alguma coisa?"). Se depois da retomada passam mais
-- 20 minutos em silencio, manda o encerramento. Sempre dentro da janela de 24 horas da Meta (contada da
-- ultima mensagem DO CLIENTE). Conversas paradas ha mais de 6 horas ficam quietas (evita acordar conversa velha).

-- 1. Duas colunas novas no resumo da conversa
alter table public.ia_conversas add column if not exists ultima_tipo text;          -- tipo da ultima mensagem: text, retomada, encerramento...
alter table public.ia_conversas add column if not exists ultima_cliente_em timestamptz;  -- quando o cliente falou pela ultima vez

-- 2. O gatilho passa a manter as duas colunas
create or replace function public.ia_atualizar_conversa() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.ia_conversas
    (telefone, nome_whatsapp, primeira_em, ultima_em, ultima_mensagem, ultima_direcao, ultima_tipo, ultima_cliente_em, total, do_cliente)
  values
    (new.telefone, nullif(new.nome_whatsapp, ''), new.criada_em, new.criada_em, left(new.texto, 200), new.direcao, new.tipo,
     case when new.direcao = 'cliente' then new.criada_em end,
     1, case when new.direcao = 'cliente' then 1 else 0 end)
  on conflict (telefone) do update set
    nome_whatsapp     = coalesce(nullif(excluded.nome_whatsapp, ''), ia_conversas.nome_whatsapp),
    ultima_em         = greatest(ia_conversas.ultima_em, excluded.ultima_em),
    ultima_mensagem   = case when excluded.ultima_em >= ia_conversas.ultima_em then excluded.ultima_mensagem else ia_conversas.ultima_mensagem end,
    ultima_direcao    = case when excluded.ultima_em >= ia_conversas.ultima_em then excluded.ultima_direcao  else ia_conversas.ultima_direcao  end,
    ultima_tipo       = case when excluded.ultima_em >= ia_conversas.ultima_em then excluded.ultima_tipo     else ia_conversas.ultima_tipo     end,
    ultima_cliente_em = greatest(ia_conversas.ultima_cliente_em, excluded.ultima_cliente_em),
    total             = ia_conversas.total + 1,
    do_cliente        = ia_conversas.do_cliente + excluded.do_cliente;
  return new;
end $$;

-- 3. Preenche as colunas novas para as conversas que ja existem
update public.ia_conversas c set
  ultima_tipo = (select m.tipo from public.ia_mensagens m where m.telefone = c.telefone order by m.criada_em desc limit 1),
  ultima_cliente_em = (select max(m.criada_em) from public.ia_mensagens m where m.telefone = c.telefone and m.direcao = 'cliente');

-- 4. A visao que o n8n le a cada 5 minutos: quem precisa de retomada ou de encerramento agora
create or replace view public.ia_para_retomar as
select c.telefone,
       c.nome_whatsapp,
       case when c.ultima_tipo = 'retomada' then 'encerramento' else 'retomada' end as etapa,
       c.ultima_em
from public.ia_conversas c
where c.ultima_direcao = 'ana'
  and c.ultima_tipo in ('text', 'retomada')
  and c.ultima_em <= now() - interval '20 minutes'
  and c.ultima_em >  now() - interval '6 hours'
  and c.ultima_cliente_em is not null
  and c.ultima_cliente_em > now() - interval '23 hours';

-- so o n8n (chave de servico) le a visao; o site nao precisa dela
revoke all on public.ia_para_retomar from anon, authenticated;
