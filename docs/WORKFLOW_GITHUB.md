# Workflow Git e GitHub

## Fluxo

`branch individual -> homolog -> main`

Cada integrante usa uma branch individual, como `vicenzo`. Pull Requests promovem trabalho para `homolog`; somente mudanças validadas seguem de `homolog` para `main`.

## Regras

- Use branches curtas vinculadas a uma task e commits objetivos em português.
- Cada PR deve indicar a task ESP, alterações, testes executados e riscos.
- Outro integrante revisa antes da integração; não faça push direto para `homolog` ou `main`.
- Formatação, análise e testes devem passar antes do merge.

Proteções remotas, revisões obrigatórias e checks exigidos precisam ser configurados no GitHub por pessoa autorizada; esta fundação não altera configurações remotas.
