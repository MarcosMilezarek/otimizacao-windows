# otimizacao-windows

Ferramenta em PowerShell para otimizar estações de trabalho Windows 10 e 11 de escritório, guiada por um perfil por cliente, com coleta de métricas antes e depois, simulação, backup e reversão.

> [!WARNING]
> Os scripts exigem administrador e **alteram o sistema**: registro, serviços, tarefas agendadas, plano de energia, aplicativos instalados e arquivos temporários. Alguns itens não têm reversão (limpezas e remoção de apps). Teste antes numa máquina não crítica ou numa máquina virtual e use sempre a simulação (`-WhatIf` ou a ação Simular do menu) antes de aplicar.

## Funcionalidades

Cada ajuste tem um código no catálogo (L1, V3, I6...) e só é aplicado se estiver na lista `Aplicar` do perfil do cliente.

| Módulo | O que faz |
|---|---|
| `src/Menu.ps1` | Janela (WinForms) para escolher o perfil e a ação: Fluxo completo, Simular, Só verificar agora e Reverter. O fluxo completo pede uma única confirmação e segue sozinho por uma tarefa agendada como SYSTEM, com as reinicializações e uma janela de acompanhamento no logon do usuário. |
| `src/Perfil.ps1` | Assistente Novo perfil, aberto pelo Menu: mostra o catálogo, lê da máquina as listas dos itens I1, I4, I9, I10 e A2 e grava `C:\ProgramData\Otimizacao\perfis\<Cliente>.psd1`. |
| `src/Coleta.ps1` | Somente leitura. Gera um JSON com sistema, hardware, saúde dos discos, desempenho em repouso, inicialização, serviços, energia, tempo de boot, eventos de hardware de 30 dias e programas instalados. No modo `-Comparar`, gera um HTML antes e depois com a faixa de ruído medida entre duas coletas iniciais. |
| `src/Manutencao.ps1` | M1 DISM ScanHealth e M2 `sfc /verifyonly` (reparo só se aprovado no perfil), M3 `Repair-Volume -Scan`, M4 TRIM ligado em SSD e M8 horário ativo do Windows Update por política. |
| `src/Aplicativos.ps1` | A1 remove apps de consumo de uma lista base (Clipchamp, Notícias, Solitaire, Xbox...), A2 remove programas do fabricante listados no perfil (Appx e MSI) e A4 remove o Teams pessoal. Protege ferramentas de driver e BIOS, Store, Edge e Segurança do Windows. |
| `src/Inicializacao.ps1` | I1 a I12: desabilita entradas de inicialização, tarefas e serviços de terceiros escolhidos, aplica políticas do Edge, do Chrome, de widgets, do Game Bar, de sugestões e do Recall, e remove o app Copilot de consumidor. Nada é excluído; o estado original é salvo. |
| `src/VisualEnergia.ps1` | V1 a V10: animações e transparência, plano Desempenho máximo (com alternativa em Modern Standby), hibernação só em desktop, Num Lock, extensões de arquivo, "Finalizar tarefa" na barra e atalho das Teclas de Aderência. |
| `src/Limpeza.ps1` | L1 a L9: temporários antigos, cache do Chrome e do Edge (nunca cookies, senhas ou histórico), cache do Windows Update, Lixeira, Windows.old, limpeza de componentes, desfragmentação só em HDD e Sensor de Armazenamento. |
| `src/Verificacao.ps1` | Somente leitura. Confirma no estado real do sistema (registro, pacotes, tarefas, serviços, energia) cada item aprovado no perfil, sem usar o log dos scripts. |
| `src/Otimizacao.Comum.psm1` | Funções comuns: pré-checagens, ponto de restauração, sessão com log e estado original, leitura e gravação de registro, reversão e acesso ao registro do usuário alvo (carrega o `NTUSER.DAT` se ele não estiver conectado). |

Todo script que altera o sistema:

- bloqueia sem administrador, com reinicialização pendente, com menos de 2 GB livres no disco do sistema, em notebook na bateria abaixo de 40% e durante instalação de atualização do Windows;
- em domínio ou com MDM, pula valores já definidos por política e avisa;
- cria um ponto de restauração e confirma que ele existe; com a Proteção do Sistema desligada, aborta sem alterar nada;
- grava o valor original de cada item e um log em `%ProgramData%\Otimizacao\<Cliente>\<data>-<Script>\` (`estado-original.json` e `log.csv`);
- aceita `-WhatIf` (lista o que mudaria, sem gravar nada) e `-Revert`.

## Requisitos

- Windows 10 ou 11.
- Windows PowerShell 5.1 (o que vem com o Windows). Não usa módulos externos.
- PowerShell aberto como administrador.
- Proteção do Sistema ligada no disco do sistema.

## Como executar

No PowerShell aberto como administrador:

```powershell
[Net.ServicePointManager]::SecurityProtocol='Tls12'; irm https://raw.githubusercontent.com/marcosmilezarek/otimizacao-windows/<commit>/Iniciar.ps1 | iex
```

Troque `<commit>` pelo hash completo (40 caracteres) de um commit deste repositório, por exemplo o último commit "Publicar". Usar um hash, e não o nome de uma branch, garante que o lançador baixado é exatamente o daquele commit.

O `Iniciar.ps1` então:

1. Aborta se o PowerShell não estiver como administrador, antes de baixar qualquer coisa.
2. Cria `C:\ProgramData\Otimizacao` e restringe o acesso (SYSTEM e Administradores com controle total, Usuários só leitura).
3. Baixa cada arquivo do commit fixado no próprio `Iniciar.ps1` para `C:\ProgramData\Otimizacao\app\.baixando-<sha7>` e confere o SHA256 de cada um. Qualquer divergência ou falha apaga a pasta temporária e aborta sem executar nada.
4. Renomeia a pasta para `app\<sha7>`. Se ela já existir íntegra, não baixa de novo.
5. Confere as permissões da pasta e de cada arquivo e abre o Menu em um processo novo.

Também é possível clonar o repositório e rodar cada script direto, sempre simulando antes:

```powershell
.\src\Limpeza.ps1 -Perfil .\perfis\ClienteX.psd1 -WhatIf
.\src\Limpeza.ps1 -Perfil .\perfis\ClienteX.psd1
.\src\Limpeza.ps1 -Perfil .\perfis\ClienteX.psd1 -Revert
```

Ordem usada pelo Menu: Manutencao, Aplicativos, Inicializacao, VisualEnergia e Limpeza.

### Fluxo completo do Menu

Reinicia; faz a Coleta antes 1; reinicia; faz a Coleta antes 2; reinicia; roda Manutencao, Aplicativos, Inicializacao, VisualEnergia e Limpeza no boot, sem logon; reinicia; faz a Coleta depois; gera a comparação em HTML e roda a Verificacao. As coletas esperam alguém entrar no Windows, porque o tempo de boot só é registrado depois do logon. O fluxo leva de 1 h 30 a 2 h e para, removendo a tarefa agendada, se um script terminar com erro, se a Manutencao encontrar corrupção ou erro de disco ou se a reinicialização pendente persistir.

## Perfis

O perfil é um arquivo `.psd1` lido com `Import-PowerShellDataFile`: só dados, nenhum código é executado. Campos de `perfis/exemplo.psd1`:

| Campo | Uso |
|---|---|
| `Cliente` | Nome do cliente (letras, números, ponto, hífen e sublinhado). Nomeia a pasta de backup. |
| `UsuarioSid` | SID do usuário cujo registro (HKCU) será alterado. Vazio = usuário conectado ao console. |
| `Aplicar` | Códigos do catálogo a aplicar, por exemplo `'L1', 'L2', 'V8'`. |
| `Pular` | Códigos a não aplicar, mesmo se estiverem em `Aplicar`. |
| `Protegidos` | Nomes que nunca são tocados, por categoria (`Inicializacao`, `Servicos`, `Tarefas`, `Aplicativos`). Aceita curinga. |
| `Opcoes` | Listas e escolhas por item: `I1Desabilitar`, `I4NegarSegundoPlano`, `I9Tarefas`, `I10Servicos`, `A2Remover`, `M1Reparar`, `M2Reparar`, `M8Inicio`, `M8Fim`, `V5DesligarInicializacaoRapida`. Lista vazia faz o item ser pulado. |

Para criar um perfil próprio:

- **Pelo Menu:** botão Novo perfil. O assistente grava `C:\ProgramData\Otimizacao\perfis\<Cliente>.psd1`.
- **À mão:** copie `perfis/exemplo.psd1` para `C:\ProgramData\Otimizacao\perfis\<Cliente>.psd1` (ou para `perfis\` de um clone), mude `Cliente` e mantenha em `Aplicar` só os itens aprovados. Os nomes para `I1Desabilitar` e `A2Remover` são os que aparecem na Coleta.

O Menu lista os perfis dessas duas pastas, exceto o `exemplo.psd1`.

## O que altera e como reverter

| Script | Reversão |
|---|---|
| Manutencao | `-Revert` restaura M4 e M8. Reparos do M1 e do M2 voltam só pelo ponto de restauração. M3 só verifica. |
| Aplicativos | Manual: `-Revert` lista o que foi removido, mostra o nome e o link da Microsoft Store (ou o instalador do fabricante, no caso de MSI) e confere o que já voltou. |
| Inicializacao | `-Revert` restaura tudo, exceto o I6: o app Copilot volta só pela Microsoft Store. |
| VisualEnergia | `-Revert` restaura todos os itens e exclui o plano de energia criado pelo script. |
| Limpeza | `-Revert` restaura L8 e L9. L1 a L7 apagam arquivos e não têm reversão. |
| Menu | Botão Reverter: simula, pede confirmação e reverte na ordem inversa (Limpeza, VisualEnergia, Inicializacao, Aplicativos, Manutencao). Para cancelar um fluxo sem o menu: `Unregister-ScheduledTask -TaskPath '\Otimizacao\' -TaskName Fluxo` (e `Acompanhar`). |
| Iniciar | Apagar a pasta `C:\ProgramData\Otimizacao\app\<sha7>`. Não cria tarefa, serviço nem atalho. |
| Coleta e Verificacao | Não alteram o sistema. |

Sem `-Sessao`, o `-Revert` reverte todas as sessões ainda não revertidas daquele script, da mais recente para a mais antiga.

## Segurança

- **Commit fixo:** o `Iniciar.ps1` baixa os scripts de um hash de commit gravado nele, e não de uma branch que pode mudar.
- **SHA256 por arquivo:** cada arquivo baixado é conferido contra o hash esperado antes de qualquer execução.
- **Permissões da pasta:** `C:\ProgramData\Otimizacao` fica com dono Administradores, controle total para SYSTEM e Administradores e só leitura para Usuários. O lançador recusa junções e links simbólicos e não abre o Menu se encontrar permissão insegura, porque os scripts rodam elevados e um usuário comum não pode conseguir trocá-los.
- **ExecutionPolicy:** o Menu e os scripts rodam com `-ExecutionPolicy Bypass` só no processo que abrem; a política da máquina não muda. Uma política `AllSigned` definida por GPO impede a execução.
- **Dados:** a Coleta lê só dados técnicos (não lê conteúdo de arquivos, senhas, chaves de licença nem histórico de navegação) e nada é enviado para fora da máquina.

## Testes

Testes em [Pester](https://pester.dev) (sintaxe do Pester 5 ou superior, testado com 6.2.0) na pasta `tests/`, um arquivo por script.

Cinco arquivos usam só mocks e `TestDrive` e podem rodar em qualquer máquina: `Otimizacao.Comum`, `Coleta`, `Iniciar`, `Perfil` e `Verificacao`.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Import-Module Pester -MinimumVersion 5.0; Invoke-Pester -Path .\tests\Otimizacao.Comum.Tests.ps1, .\tests\Coleta.Tests.ps1, .\tests\Iniciar.Tests.ps1, .\tests\Perfil.Tests.ps1, .\tests\Verificacao.Tests.ps1 -Output Detailed"
```

Os outros seis (`Aplicativos`, `Inicializacao`, `Limpeza`, `Manutencao`, `Menu` e `VisualEnergia`) aplicam e revertem alterações reais, registram tarefas e reiniciam. Por isso abortam se a variável de ambiente `OTIMIZACAO_VM` não for `1` e devem rodar só numa máquina virtual descartável.

Análise estática:

```powershell
Invoke-ScriptAnalyzer -Path .\src -Recurse
```

## Estrutura

```text
Iniciar.ps1                  lançador (irm | iex): baixa, confere SHA256 e abre o Menu
perfis/
  exemplo.psd1               modelo de perfil de cliente
src/
  Menu.ps1                   janela principal e fluxo completo
  Perfil.ps1                 assistente Novo perfil
  Coleta.ps1                 coleta somente leitura e comparação antes e depois
  Manutencao.ps1             M1 a M4 e M8
  Aplicativos.ps1            A1 a A4
  Inicializacao.ps1          I1 a I12
  VisualEnergia.ps1          V1 a V10
  Limpeza.ps1                L1 a L9
  Verificacao.ps1            verificação final, somente leitura
  Otimizacao.Comum.psm1      funções comuns
tests/                       testes Pester, um arquivo por script
```

## Autor

Marcos Alexandre Milezarek. [LinkedIn](https://www.linkedin.com/in/marcosmilezarek/)
