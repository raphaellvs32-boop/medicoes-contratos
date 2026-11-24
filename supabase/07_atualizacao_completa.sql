-- =====================================================================
-- ATUALIZAÇÃO COMPLETA — rodar UMA vez no Supabase: SQL Editor > New query > colar TUDO > Run
-- Junta: cadastro de pessoas (05) + Acabou de acontecer / ao vivo (06).
-- Pode rodar de novo sem problema. Requer o 01_estrutura.sql já rodado.
-- =====================================================================

alter table public.perfis add column if not exists trocar_senha boolean not null default false;

-- Auditoria passa a aceitar um "modo silencioso" (para a função de cadastro registrar uma linha só)
create or replace function public.audita() returns trigger
language plpgsql security definer set search_path = public as $$
declare d text; a text; r record;
begin
  if tg_op = 'DELETE' then r := old; else r := new; end if;
  if auth.uid() is null or current_setting('gmc.silencio', true) = '1' then return r; end if;
  if tg_table_name = 'medicoes' then
    a := case tg_op when 'INSERT' then 'Lançou medição' when 'UPDATE' then 'Alterou medição' else 'Excluiu medição' end;
    d := coalesce(r.contrato, '-') || ' · FR ' || coalesce(r.fr, '-') || ' · R$ ' || r.valor;
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

-- Administrador cadastra uma pessoa com senha provisória (acesso já liberado)
create or replace function public.admin_criar_usuario(p_email text, p_nome text, p_senha text, p_perfil text, p_acessos jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare uid uuid; v_email text := lower(trim(p_email));
begin
  if not public.sou_admin() then raise exception 'Somente administradores podem cadastrar pessoas.'; end if;
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then raise exception 'E-mail inválido.'; end if;
  if coalesce(trim(p_nome), '') = '' then raise exception 'Informe o nome.'; end if;
  if length(coalesce(p_senha, '')) < 8 then raise exception 'A senha provisória precisa ter pelo menos 8 caracteres.'; end if;
  if p_perfil not in ('Administrador','Gestor','Lançador','Consulta') then raise exception 'Perfil inválido.'; end if;
  if exists (select 1 from auth.users where lower(email) = v_email) then raise exception 'Este e-mail já tem acesso cadastrado.'; end if;
  uid := gen_random_uuid();
  perform set_config('gmc.silencio', '1', true);
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          confirmation_token, email_change, email_change_token_new, recovery_token)
  values ('00000000-0000-0000-0000-000000000000', uid, 'authenticated', 'authenticated', v_email,
          extensions.crypt(p_senha, extensions.gen_salt('bf')), now(),
          '{"provider":"email","providers":["email"]}'::jsonb, jsonb_build_object('nome', trim(p_nome)), now(), now(), '', '', '', '');
  insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  values (gen_random_uuid(), uid, uid::text, jsonb_build_object('sub', uid::text, 'email', v_email, 'email_verified', true), 'email', now(), now(), now());
  update public.perfis set nome = trim(p_nome), perfil = p_perfil, ativo = true, acessos = p_acessos, trocar_senha = true where id = uid;
  perform set_config('gmc.silencio', '0', true);
  insert into public.auditoria (por, por_nome, acao, detalhe) values (auth.uid(), public.meu_nome(), 'Cadastrou usuário', v_email || ' · ' || p_perfil);
  return uid;
end $$;

-- Administrador define uma nova senha provisória para alguém
create or replace function public.admin_redefinir_senha(p_id uuid, p_senha text)
returns void language plpgsql security definer set search_path = public as $$
declare v_email text;
begin
  if not public.sou_admin() then raise exception 'Somente administradores podem redefinir senhas.'; end if;
  if length(coalesce(p_senha, '')) < 8 then raise exception 'A senha provisória precisa ter pelo menos 8 caracteres.'; end if;
  update auth.users set encrypted_password = extensions.crypt(p_senha, extensions.gen_salt('bf')), email_confirmed_at = coalesce(email_confirmed_at, now()), updated_at = now()
   where id = p_id returning email into v_email;
  if v_email is null then raise exception 'Usuário não encontrado.'; end if;
  perform set_config('gmc.silencio', '1', true);
  update public.perfis set trocar_senha = (p_id <> auth.uid()) where id = p_id;
  perform set_config('gmc.silencio', '0', true);
  insert into public.auditoria (por, por_nome, acao, detalhe) values (auth.uid(), public.meu_nome(), 'Redefiniu senha', v_email);
end $$;

-- A própria pessoa avisa que já trocou a senha provisória
create or replace function public.senha_trocada()
returns void language plpgsql security definer set search_path = public as $$
begin
  perform set_config('gmc.silencio', '1', true);
  update public.perfis set trocar_senha = false where id = auth.uid();
  perform set_config('gmc.silencio', '0', true);
  if auth.uid() is not null then insert into public.auditoria (por, por_nome, acao, detalhe) values (auth.uid(), public.meu_nome(), 'Trocou a senha', null); end if;
end $$;

revoke execute on function public.admin_criar_usuario(text, text, text, text, jsonb) from public, anon;
revoke execute on function public.admin_redefinir_senha(uuid, text) from public, anon;
revoke execute on function public.senha_trocada() from public, anon;
grant execute on function public.admin_criar_usuario(text, text, text, text, jsonb) to authenticated;
grant execute on function public.admin_redefinir_senha(uuid, text) to authenticated;
grant execute on function public.senha_trocada() to authenticated;

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


-- Faz o Supabase reconhecer as funções novas imediatamente
notify pgrst, 'reload schema';

-- Conferência: deve mostrar 3 linhas (admin_criar_usuario, admin_redefinir_senha, senha_trocada)
select p.proname as funcao_instalada
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname in ('admin_criar_usuario', 'admin_redefinir_senha', 'senha_trocada')
order by 1;
