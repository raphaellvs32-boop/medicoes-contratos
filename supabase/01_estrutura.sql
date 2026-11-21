-- =====================================================================
-- Sistema de Medições e Contratos — estrutura do banco (Supabase)
-- Rodar UMA vez no Supabase: SQL Editor > New query > colar > Run.
-- Pode rodar de novo sem perder dados (usa "if not exists").
-- =====================================================================

-- ---------- Perfis de usuário (ligados ao login do Supabase) ----------
create table if not exists public.perfis (
  id         uuid primary key references auth.users(id) on delete cascade,
  email      text not null,
  nome       text not null default '',
  perfil     text not null default 'Pendente'
             check (perfil in ('Administrador','Gestor','Lançador','Consulta','Pendente')),
  ativo      boolean not null default false,
  acessos    jsonb not null default
             '{"inicio":"nao","medicao":"nao","contratos":"nao","alertas":"nao","relatorios":"nao","config":"nao"}'::jsonb,
  criado_em  timestamptz not null default now()
);

-- ---------- E-mails que entram sempre como Administrador ----------
create table if not exists public.admins_previstos (
  email text primary key check (email = lower(email))
);
alter table public.admins_previstos enable row level security;  -- sem regras: ninguém lê pelo site

-- ---------- Parâmetros de alerta (uma linha só) ----------
create table if not exists public.parametros (
  id             int primary key default 1 check (id = 1),
  amarelo        int not null default 90,
  vermelho       int not null default 60,
  verba1         int not null default 80,
  verba2         int not null default 90,
  atualizado_em  timestamptz not null default now(),
  atualizado_por uuid,
  check (vermelho > 0 and amarelo > vermelho),
  check (verba1 > 0 and verba2 > verba1 and verba2 <= 100)
);
insert into public.parametros (id) values (1) on conflict (id) do nothing;

-- ---------- Contratos ----------
create table if not exists public.contratos (
  contrato            text primary key check (contrato ~ '^[0-9]{10}$'),
  cod_fornecedor      text,
  fornecedor          text not null,
  servico             text not null,
  localidade          text,
  inicio              date,
  fim                 date not null,
  valor_contrato      numeric(14,2) not null check (valor_contrato >= 0),
  custo_incorrido_sap numeric(14,2) not null default 0,
  status              text not null default 'Vigente'
                      check (status in ('Vigente','Em aditamento','Encerrado','Cancelado')),
  gestor              text,
  observacao          text,
  criado_em           timestamptz not null default now(),
  atualizado_em       timestamptz not null default now(),
  atualizado_por      uuid
);

create table if not exists public.contrato_historico (
  id        bigserial primary key,
  contrato  text not null references public.contratos(contrato) on update cascade on delete cascade,
  em        timestamptz not null default now(),
  por       uuid default auth.uid(),
  por_nome  text,
  acao      text not null
);
create index if not exists contrato_historico_contrato_idx on public.contrato_historico (contrato);

-- ---------- Medições (histórico da planilha + lançamentos do sistema) ----------
create table if not exists public.medicoes (
  id                 bigserial primary key,
  origem             text not null default 'sistema' check (origem in ('planilha','sistema')),
  item_planilha      int,
  tipo_contrato      text,
  localidade         text,
  tipo               text default 'Medição',
  area_delegada      text,
  ini                date,
  fim                date,
  mes                date check (mes is null or extract(day from mes) = 1),
  efeito_raf3        text,
  tipo_projeto       text,
  projeto            text,
  status_projeto     text,
  elemento           text,
  cc                 text,
  contrato           text,
  status_contrato    text,
  incidencia         text,
  fornecedor         text,
  emissor            text,
  dt_emissao         date,
  pedido             text,
  item               text,
  fr                 text,
  status_fr          text check (status_fr in ('Pendente','Aprovada','Cancelada')),
  valor              numeric(14,2) not null check (valor >= 0),
  valor_anterior     numeric(14,2),
  provisao           text,
  valor_provisionado numeric(14,2),
  documento_prov     text,
  nf                 text,
  status_processo    text check (status_processo in ('Pendente','Concluído')),
  servico            text,
  obs                text,
  criado_por         uuid default auth.uid(),
  criado_nome        text,
  criado_em          timestamptz not null default now(),
  alterado_por       uuid,
  alterado_em        timestamptz,
  -- lançamentos novos precisam de mês, contrato e pedido válidos
  check (origem = 'planilha' or (mes is not null and contrato ~ '^[0-9]{10}$' and pedido ~ '^[0-9]{10}$'))
);
create index if not exists medicoes_mes_idx      on public.medicoes (mes);
create index if not exists medicoes_contrato_idx on public.medicoes (contrato);
create index if not exists medicoes_projeto_idx  on public.medicoes (projeto);
create index if not exists medicoes_cc_idx       on public.medicoes (cc);
create index if not exists medicoes_fr_idx       on public.medicoes (fr);
create unique index if not exists medicoes_item_planilha_uk on public.medicoes (item_planilha) where origem = 'planilha';

-- ---------- Auditoria (gravada pelo próprio banco, ninguém edita) ----------
create table if not exists public.auditoria (
  id       bigserial primary key,
  em       timestamptz not null default now(),
  por      uuid,
  por_nome text,
  acao     text not null,
  detalhe  text
);
create index if not exists auditoria_em_idx on public.auditoria (em desc);

-- =====================================================================
-- Funções de acesso
-- =====================================================================
create or replace function public.meu_nivel(modulo text) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select case when p.ativo then p.acessos ->> modulo end from public.perfis p where p.id = auth.uid()),
    'nao')
$$;

create or replace function public.sou_ativo() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select p.ativo from public.perfis p where p.id = auth.uid()), false)
$$;

create or replace function public.sou_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select public.meu_nivel('config') = 'editar'
$$;

create or replace function public.meu_nome() returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select nullif(p.nome, '') from public.perfis p where p.id = auth.uid()), 'sistema')
$$;

-- =====================================================================
-- Gatilhos
-- =====================================================================

-- Novo login criado no Supabase => cria o perfil.
-- O primeiro usuário, ou um e-mail da lista admins_previstos, vira Administrador; os demais entram bloqueados até o admin liberar.
create or replace function public.ao_criar_usuario() returns trigger
language plpgsql security definer set search_path = public as $$
declare tem_admin boolean;
begin
  select exists (select 1 from public.perfis where ativo and acessos ->> 'config' = 'editar')
     and not exists (select 1 from public.admins_previstos a where a.email = lower(new.email))
    into tem_admin;
  insert into public.perfis (id, email, nome, perfil, ativo, acessos)
  values (
    new.id, new.email,
    coalesce(nullif(new.raw_user_meta_data ->> 'nome', ''), split_part(new.email, '@', 1)),
    case when tem_admin then 'Pendente' else 'Administrador' end,
    not tem_admin,
    case when tem_admin
      then '{"inicio":"nao","medicao":"nao","contratos":"nao","alertas":"nao","relatorios":"nao","config":"nao"}'::jsonb
      else '{"inicio":"ver","medicao":"editar","contratos":"editar","alertas":"ver","relatorios":"ver","config":"editar"}'::jsonb end
  )
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists ao_criar_usuario on auth.users;
create trigger ao_criar_usuario after insert on auth.users
  for each row execute function public.ao_criar_usuario();

-- Nunca ficar sem administrador ativo.
create or replace function public.protege_admin() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.ativo and old.acessos ->> 'config' = 'editar'
     and (not new.ativo or new.acessos ->> 'config' is distinct from 'editar')
     and not exists (select 1 from public.perfis p where p.id <> old.id and p.ativo and p.acessos ->> 'config' = 'editar') then
    raise exception 'Precisa existir pelo menos um administrador ativo.';
  end if;
  if new.id = auth.uid() and not new.ativo then
    raise exception 'Você não pode bloquear a própria conta.';
  end if;
  new.email := old.email;  -- e-mail só muda pelo login
  return new;
end $$;
drop trigger if exists protege_admin on public.perfis;
create trigger protege_admin before update on public.perfis
  for each row execute function public.protege_admin();

-- Carimbo de quem lançou/alterou a medição.
create or replace function public.carimbo_medicao() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if auth.uid() is not null then
      new.criado_por := auth.uid(); new.criado_nome := public.meu_nome(); new.origem := 'sistema'; new.criado_em := now();
    end if;
  else
    new.criado_por := old.criado_por; new.criado_nome := old.criado_nome; new.criado_em := old.criado_em; new.origem := old.origem;
    if auth.uid() is not null then new.alterado_por := auth.uid(); new.alterado_em := now(); end if;
  end if;
  return new;
end $$;
drop trigger if exists carimbo_medicao on public.medicoes;
create trigger carimbo_medicao before insert or update on public.medicoes
  for each row execute function public.carimbo_medicao();

create or replace function public.carimbo_contrato() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.atualizado_em := now();
  if auth.uid() is not null then new.atualizado_por := auth.uid(); end if;
  if tg_op = 'UPDATE' then new.criado_em := old.criado_em; end if;
  return new;
end $$;
drop trigger if exists carimbo_contrato on public.contratos;
create trigger carimbo_contrato before insert or update on public.contratos
  for each row execute function public.carimbo_contrato();

create or replace function public.carimbo_historico() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.por := auth.uid(); new.por_nome := public.meu_nome(); new.em := now();
  return new;
end $$;
drop trigger if exists carimbo_historico on public.contrato_historico;
create trigger carimbo_historico before insert on public.contrato_historico
  for each row execute function public.carimbo_historico();

-- Auditoria automática (cargas feitas pelo SQL Editor não entram, pois não têm usuário logado).
create or replace function public.audita() returns trigger
language plpgsql security definer set search_path = public as $$
declare d text; a text; r record;
begin
  if tg_op = 'DELETE' then r := old; else r := new; end if;
  if auth.uid() is null then return r; end if;
  if tg_table_name = 'medicoes' then
    a := case tg_op when 'INSERT' then 'Lançou medição' when 'UPDATE' then 'Alterou medição' else 'Excluiu medição' end;
    d := coalesce(r.contrato, '-') || ' · FR ' || coalesce(r.fr, '-') || ' · R$ ' || r.valor;
  elsif tg_table_name = 'contratos' then
    a := case tg_op when 'INSERT' then 'Cadastrou contrato' when 'UPDATE' then 'Alterou contrato' else 'Excluiu contrato' end;
    d := r.contrato || ' · ' || r.fornecedor;
  elsif tg_table_name = 'perfis' then
    a := 'Alterou usuário'; d := new.email || ' · ' || new.perfil || case when new.ativo then ' · ativo' else ' · bloqueado' end;
  elsif tg_table_name = 'parametros' then
    a := 'Alterou parâmetros de alerta'; d := 'amarelo ' || new.amarelo || ' · vermelho ' || new.vermelho || ' · verba ' || new.verba1 || '/' || new.verba2;
  end if;
  insert into public.auditoria (por, por_nome, acao, detalhe) values (auth.uid(), public.meu_nome(), a, d);
  return r;
end $$;
drop trigger if exists audita on public.medicoes;
create trigger audita after insert or update or delete on public.medicoes for each row execute function public.audita();
drop trigger if exists audita on public.contratos;
create trigger audita after insert or update or delete on public.contratos for each row execute function public.audita();
drop trigger if exists audita on public.perfis;
create trigger audita after update on public.perfis for each row execute function public.audita();
drop trigger if exists audita on public.parametros;
create trigger audita after update on public.parametros for each row execute function public.audita();

-- Registro de entrada no sistema (chamado pelo app após o login).
create or replace function public.registrar_entrada() returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and public.sou_ativo() then
    insert into public.auditoria (por, por_nome, acao, detalhe) values (auth.uid(), public.meu_nome(), 'Entrou no sistema', null);
  end if;
end $$;

-- =====================================================================
-- Segurança por linha (RLS): cada usuário só faz o que o perfil libera
-- =====================================================================
alter table public.perfis             enable row level security;
alter table public.parametros         enable row level security;
alter table public.contratos          enable row level security;
alter table public.contrato_historico enable row level security;
alter table public.medicoes           enable row level security;
alter table public.auditoria          enable row level security;

drop policy if exists perfis_ler on public.perfis;
create policy perfis_ler on public.perfis for select to authenticated using (id = auth.uid() or public.sou_admin());
drop policy if exists perfis_alterar on public.perfis;
create policy perfis_alterar on public.perfis for update to authenticated using (public.sou_admin()) with check (public.sou_admin());
drop policy if exists perfis_excluir on public.perfis;
create policy perfis_excluir on public.perfis for delete to authenticated using (public.sou_admin() and id <> auth.uid());

drop policy if exists parametros_ler on public.parametros;
create policy parametros_ler on public.parametros for select to authenticated using (public.sou_ativo());
drop policy if exists parametros_alterar on public.parametros;
create policy parametros_alterar on public.parametros for update to authenticated using (public.sou_admin()) with check (public.sou_admin());

drop policy if exists contratos_ler on public.contratos;
create policy contratos_ler on public.contratos for select to authenticated using (public.sou_ativo());
drop policy if exists contratos_incluir on public.contratos;
create policy contratos_incluir on public.contratos for insert to authenticated with check (public.meu_nivel('contratos') = 'editar');
drop policy if exists contratos_alterar on public.contratos;
create policy contratos_alterar on public.contratos for update to authenticated using (public.meu_nivel('contratos') = 'editar') with check (public.meu_nivel('contratos') = 'editar');
drop policy if exists contratos_excluir on public.contratos;
create policy contratos_excluir on public.contratos for delete to authenticated using (public.sou_admin());

drop policy if exists historico_ler on public.contrato_historico;
create policy historico_ler on public.contrato_historico for select to authenticated using (public.sou_ativo());
drop policy if exists historico_incluir on public.contrato_historico;
create policy historico_incluir on public.contrato_historico for insert to authenticated with check (public.meu_nivel('contratos') = 'editar');

drop policy if exists medicoes_ler on public.medicoes;
create policy medicoes_ler on public.medicoes for select to authenticated using (public.sou_ativo());
drop policy if exists medicoes_incluir on public.medicoes;
create policy medicoes_incluir on public.medicoes for insert to authenticated with check (public.meu_nivel('medicao') = 'editar');
drop policy if exists medicoes_alterar on public.medicoes;
create policy medicoes_alterar on public.medicoes for update to authenticated using (public.meu_nivel('medicao') = 'editar') with check (public.meu_nivel('medicao') = 'editar');
drop policy if exists medicoes_excluir on public.medicoes;
create policy medicoes_excluir on public.medicoes for delete to authenticated
  using ((origem = 'sistema' and public.meu_nivel('medicao') = 'editar') or public.sou_admin());

drop policy if exists auditoria_ler on public.auditoria;
create policy auditoria_ler on public.auditoria for select to authenticated using (public.sou_admin());

-- Permissões de tabela (o RLS acima é quem filtra de fato). Visitantes sem login não acessam nada.
revoke all on public.admins_previstos from anon, authenticated;
revoke all on public.perfis, public.parametros, public.contratos, public.contrato_historico, public.medicoes, public.auditoria from anon;
grant select, update, delete on public.perfis to authenticated;
grant select, update on public.parametros to authenticated;
grant select, insert, update, delete on public.contratos to authenticated;
grant select, insert on public.contrato_historico to authenticated;
grant select, insert, update, delete on public.medicoes to authenticated;
grant select on public.auditoria to authenticated;
grant usage, select on all sequences in schema public to authenticated;
grant execute on function public.registrar_entrada() to authenticated;
revoke execute on function public.registrar_entrada() from anon;
