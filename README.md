# Medições e Contratos

Sistema web de medição de fornecedores (custo): lançamento de BM com pedido e FR, cadastro e aditivos de contratos, farol de vencimento (amarelo a 90 dias, vermelho a 60), farol de verba, indicadores mês a mês por projeto e centro de custo, e controle de usuários por perfil.

- **Site:** publicado pelo GitHub Pages a partir deste repositório (`index.html`).
- **Dados:** banco Supabase. Nenhum dado fica neste repositório.
- **Instalável:** no Chrome ou no Edge, use "Instalar aplicativo"; no celular, "Adicionar à tela inicial".

## Arquivos

| Arquivo | Conteúdo |
|---|---|
| `index.html` | O sistema inteiro (telas, regras, gráficos). Bibliotecas e fontes já embutidas. |
| `supabase/01_estrutura.sql` | Tabelas, regras de acesso (RLS) e auditoria. Roda uma vez no SQL Editor do Supabase. |
| `manifest.webmanifest`, `sw.js`, `icon-*.png` | Instalação como aplicativo. |

## Configuração do Supabase

1. **SQL Editor:** rodar `supabase/01_estrutura.sql`. Depois, os arquivos de carga da planilha, que são entregues à parte e **não** ficam aqui, porque este repositório é público.
2. **Authentication › URL Configuration:** em **Site URL**, colocar o endereço do GitHub Pages; em **Redirect URLs**, o mesmo endereço.
3. **Authentication › Sign In / Providers:** e-mail ligado e cadastro de novos usuários ligado. Contas novas entram bloqueadas até o administrador liberar.
4. A URL do projeto e a chave **publishable/anon** ficam no começo do script do `index.html` (`SUPABASE_URL` e `SUPABASE_ANON_KEY`). Essa chave é pública por natureza: quem protege os dados são as regras RLS do banco. A chave **service_role/secret nunca** entra aqui.

## Perfis

| Perfil | Pode |
|---|---|
| Administrador | Tudo, inclusive liberar usuários, alterar parâmetros de alerta e ver a auditoria |
| Gestor | Lançar medições e cadastrar ou alterar contratos |
| Lançador | Lançar medições; consulta contratos e alertas |
| Consulta | Somente leitura |

O primeiro cadastro do sistema vira Administrador. O banco impede que o último administrador seja bloqueado.
