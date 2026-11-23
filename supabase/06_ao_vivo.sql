-- =====================================================================
-- "Acabou de acontecer" + atualização ao vivo
-- Rodar UMA vez no Supabase: SQL Editor > New query > colar > Run (pode rodar de novo)
-- =====================================================================

-- 1) Auditoria com textos mais claros (inclui "Aprovou FR")
create or replace function public.audita() returns trigger
language plpgsql security definer set search_path = public as $$
declare d text; a text; r record;
  br text;
begin
  if tg_op = 'DELETE' then r := old; else r := new; end if;
  if auth.uid() is null or current_setting('gmc.silencio', true) = '1' then return r; end if;
  if tg_table_name = 'medicoes' then
    br := 'R$ ' || translate(to_char(r.valor, 'FM999,999,999,990.00'), ',.', '.,');
    if tg_op = 'UPDATE' and new.status_fr = 'Aprovada' and old.status_fr is distinct from 'Aprovada' then
      a := 'Aprovou FR';
      d := 'FR ' || coalesce(new.fr, '-') || ' · pedido ' || coalesce(new.pedido, '-') || ' · ' || coalesce(new.contrato, '-') || ' · ' || br;
    else
      a := case tg_op when 'INSERT' then 'Lançou medição' when 'UPDATE' then 'Alterou medição' else 'Excluiu medição' end;
      d := 'pedido ' || coalesce(r.pedido, '-') || ' · ' || coalesce(r.contrato, '-') || ' · ' || coalesce(r.fornecedor, '-') || ' · ' || br;
    end if;
  elsif tg_table_name = 'contratos' then
    a := case tg_op when 'INSERT' then 'Cadastrou contrato' when 'UPDATE' then 'Alterou contrato' else 'Excluiu contrato' end;
    d := r.contrato || ' · ' || r.fornecedor;
  elsif tg_table_name = 'perfis' then
    if new.trocar_senha is distinct from old.trocar_senha and new.perfil = old.perfil and new.ativo = old.ativo and new.acessos = old.acessos and new.nome = old.nome then return r; end if;
    a := 'Alterou usuário'; d := new.email || ' · ' || new.perfil || case when new.ativo then ' · ativo' else ' · bloqueado' end;
  elsif tg_table_name = 'parametros' then
    a := 'Alterou parâmetros de alerta'; d := 'amarelo ' || new.amarelo || ' · vermelho ' || new.vermelho || ' · verba ' || new.verba1 || '/' || new.verba2;
  end if;
  insert into public.auditoria (por, por_nome, acao, detalhe) values (auth.uid(), public.meu_nome(), a, d);
  return r;
end $$;

-- 2) Todos os usuários ativos veem os eventos de medição e contrato; o resto continua só para o administrador
drop policy if exists auditoria_ler on public.auditoria;
create policy auditoria_ler on public.auditoria for select to authenticated using (
  public.sou_admin()
  or (public.sou_ativo() and acao in ('Lançou medição', 'Alterou medição', 'Aprovou FR', 'Excluiu medição', 'Cadastrou contrato', 'Alterou contrato'))
);

-- 3) Atualização em tempo real (as telas atualizam sozinhas)
alter table public.medicoes replica identity full;
alter table public.contratos replica identity full;
do $$ begin alter publication supabase_realtime add table public.medicoes;           exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.contratos;          exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.contrato_historico; exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.auditoria;          exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.parametros;         exception when duplicate_object then null; end $$;

-- Conferência: deve listar as 5 tabelas acima
select tablename from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' order by 1;
