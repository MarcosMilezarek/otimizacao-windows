<#
.SYNOPSIS
    Menu principal: escolhe o perfil do cliente e a ação, e conduz sozinho o fluxo completo, com as reinicializações.

.DESCRIPTION
    Sem parâmetros abre o menu (exige administrador):
      1  Simular: executa com -WhatIf cada script com item no perfil, na ordem do fluxo. Nada é alterado.
      2  Fluxo completo: simula, mostra as etapas e pede uma única confirmação (S/N). Depois disso não há nenhum
         prompt: o fluxo segue por uma tarefa agendada que roda como SYSTEM a cada inicialização.
      3  Só verificar: executa a Verificacao agora e mostra o resultado.
      4  Reverter: simula a reversão dos scripts com sessão não revertida, pede confirmação (S/N) e reverte na ordem
         inversa (Limpeza, VisualEnergia, Inicializacao, Aplicativos, Manutencao).
      5  Cancelar o fluxo em andamento (com fluxo em andamento, é a única ação disponível além de sair).

    Etapas do fluxo completo (script sem item aplicável no perfil é omitido):
      Reiniciar; Coleta antes 1 (espera alguém entrar no Windows); Reiniciar; Coleta antes 2 (espera logon); Reiniciar;
      Manutencao, Aplicativos, Inicializacao, VisualEnergia e Limpeza no boot, sem logon (com reinicialização pendente
      antes de um script, reinicia e tenta de novo, no máximo 2 vezes por script); Reiniciar; Coleta depois (espera
      logon); comparação antes e depois (HTML); Verificacao por último, com a mensagem aberta no Bloco de Notas na
      sessão do usuário conectado.
    As coletas esperam logon porque o tempo de boot (evento 100 de Diagnostics-Performance) só é gravado depois dele e
    os programas de inicialização do usuário só rodam com alguém conectado.

    O fluxo para, remove a tarefa e mostra o motivo quando: um script termina com erro (código de saída diferente de 0,
    inclusive pré-checagem bloqueada e falha no ponto de restauração), a Manutencao registra achado (corrupção ou erro
    de disco, linhas "ATENÇÃO" do log), a Coleta não gera o arquivo ou a reinicialização pendente persiste.
    Uma etapa interrompida por queda de energia é executada de novo no boot seguinte (os scripts são idempotentes).

    Pasta do fluxo: %ProgramData%\Otimizacao\<Cliente>\<yyyyMMdd-HHmmss>-Fluxo com fluxo.json (estado), fluxo.log,
    perfil.psd1 (cópia congelada; UsuarioSid vazio vira o usuário conectado na hora do menu), src (cópia dos scripts,
    para o fluxo não depender do pendrive), saída de cada etapa, coletas, comparacao.html, verificacao.txt e
    mensagem.txt. Acesso restrito a SYSTEM e Administradores (usuários só leem), porque a tarefa executa como SYSTEM
    os scripts dessa pasta.

.PARAMETER Continuar
    Uso interno da tarefa agendada: pasta do fluxo a continuar. Não interativo.

.EXAMPLE
    .\Menu.ps1

.NOTES
    O que altera: cria a tarefa \Otimizacao\Fluxo (SYSTEM, na inicialização), removida ao concluir, falhar ou cancelar,
    e por alguns segundos a tarefa \Otimizacao\Mensagem (usuário conectado), que abre a mensagem final. Reinicia o
    computador nas etapas do fluxo, com aviso de 60 s quando há alguém conectado. Os scripts chamados alteram o sistema
    conforme o perfil, cada um com o próprio ponto de restauração e backup.
    O que se perde: o uso do computador durante o fluxo (cerca de 1 h 30 a 2 h, com as três coletas).
    Reversão: opção 4 do menu. Cancelar sem o menu: Unregister-ScheduledTask -TaskPath '\Otimizacao\' -TaskName Fluxo.
    Política de execução definida por GPO (MachinePolicy AllSigned) impede -ExecutionPolicy Bypass e o fluxo.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Menu interativo: texto colorido só para a tela. A parte executada pela tarefa não usa Write-Host.')]
[CmdletBinding(DefaultParameterSetName = 'Menu')]
param(
    [Parameter(ParameterSetName = 'Continuar', Mandatory)]
    [string]$Continuar
)

Import-Module (Join-Path $PSScriptRoot 'Otimizacao.Comum.psm1') -Force

$script:RaizFluxo = Join-Path $env:ProgramData 'Otimizacao'
$script:PowerShellExe = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script:PastaTarefa = '\Otimizacao\'
$script:TarefaFluxo = 'Fluxo'
$script:TarefaMensagem = 'Mensagem'
$script:MaxReinicioPendente = 2
$script:AvisoReinicioSegundos = 60

# Ordem aprovada e itens que fazem cada script alterar algo (M5 a M7 são da Coleta; A3 não altera).
$script:Scripts = @(
    [pscustomobject]@{ Nome = 'Manutencao'; Prefixo = 'M'; Padrao = '^M[12348]$' }
    [pscustomobject]@{ Nome = 'Aplicativos'; Prefixo = 'A'; Padrao = '^A[124]$' }
    [pscustomobject]@{ Nome = 'Inicializacao'; Prefixo = 'I'; Padrao = '^I\d{1,2}$' }
    [pscustomobject]@{ Nome = 'VisualEnergia'; Prefixo = 'V'; Padrao = '^V\d{1,2}$' }
    [pscustomobject]@{ Nome = 'Limpeza'; Prefixo = 'L'; Padrao = '^L\d$' }
)

#region Plano e estado do fluxo

function Get-ScriptAplicavel {
    <# Nomes dos scripts, na ordem do fluxo, com ao menos um item que altera o sistema no perfil. #>
    [OutputType([string[]])]
    param([Parameter(Mandatory)]$Perfil)
    @(foreach ($s in $script:Scripts) {
            if (@(Get-ItemPerfil -Perfil $Perfil -Prefixo $s.Prefixo | Where-Object { $_ -match $s.Padrao }).Count) { $s.Nome }
        })
}

function New-EtapaFluxo {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Só cria objeto em memória.')]
    param([string]$Tipo, [string]$Nome, [string]$Rotulo)
    [pscustomobject]@{ Tipo = $Tipo; Nome = $Nome; Rotulo = $Rotulo; Status = 'Pendente'; Tentativas = 0; Inicio = $null; Fim = $null; Detalhe = $null; Arquivo = $null }
}

function Get-PlanoFluxo {
    <# Etapas do fluxo completo para os scripts aplicáveis. #>
    param([Parameter(Mandatory)][string[]]$Scripts)
    New-EtapaFluxo -Tipo Reiniciar -Nome 'Reiniciar'
    New-EtapaFluxo -Tipo Coleta -Nome 'Coleta antes 1' -Rotulo 'antes1'
    New-EtapaFluxo -Tipo Reiniciar -Nome 'Reiniciar'
    New-EtapaFluxo -Tipo Coleta -Nome 'Coleta antes 2' -Rotulo 'antes2'
    New-EtapaFluxo -Tipo Reiniciar -Nome 'Reiniciar'
    foreach ($s in $Scripts) { New-EtapaFluxo -Tipo Script -Nome $s -Rotulo $s }
    New-EtapaFluxo -Tipo Reiniciar -Nome 'Reiniciar (final)'
    New-EtapaFluxo -Tipo Coleta -Nome 'Coleta depois' -Rotulo 'depois'
    New-EtapaFluxo -Tipo Comparar -Nome 'Comparação antes e depois'
    New-EtapaFluxo -Tipo Verificar -Nome 'Verificação final'
}

function Get-EstadoFluxo {
    param([Parameter(Mandatory)][string]$Pasta)
    [IO.File]::ReadAllText((Join-Path $Pasta 'fluxo.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
}

function Save-EstadoFluxo {
    param([Parameter(Mandatory)][string]$Pasta, [Parameter(Mandatory)]$Estado)
    $Estado.Etapas = @($Estado.Etapas)
    [IO.File]::WriteAllText((Join-Path $Pasta 'fluxo.json'), (ConvertTo-Json -InputObject $Estado -Depth 5), (New-Object Text.UTF8Encoding $true))
}

function Write-RegistroFluxo {
    <# Linha com data no fluxo.log (diagnóstico do que a tarefa fez em cada boot). #>
    param([Parameter(Mandatory)][string]$Pasta, [Parameter(Mandatory)][string]$Texto)
    [IO.File]::AppendAllText((Join-Path $Pasta 'fluxo.log'), ('{0}  {1}{2}' -f (Get-Date).ToString('s'), $Texto, [Environment]::NewLine), (New-Object Text.UTF8Encoding $true))
}

function Get-FluxoEmAndamento {
    <# Pastas de fluxo com estado EmAndamento, de qualquer cliente. #>
    param([string]$Raiz = $script:RaizFluxo)
    foreach ($f in @(Get-ChildItem -Path (Join-Path $Raiz '*\*-Fluxo\fluxo.json') -ErrorAction SilentlyContinue)) {
        $e = Get-EstadoFluxo -Pasta $f.DirectoryName
        if ($e.Status -eq 'EmAndamento') { [pscustomobject]@{ Pasta = $f.DirectoryName; Estado = $e } }
    }
}

#endregion

#region Preparação do fluxo

function Set-AcessoRestrito {
    <# SYSTEM e Administradores com controle total, Usuários só leitura, sem herança. SIDs: independe do idioma. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Chamada só depois da confirmação do menu.')]
    param([Parameter(Mandatory)][string]$Pasta)
    & "$env:windir\System32\icacls.exe" $Pasta /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls falhou ao restringir $Pasta (código $LASTEXITCODE)." }
}

function Copy-PerfilFluxo {
    <# Cópia congelada do perfil. Com UsuarioSid vazio, grava o SID recebido no lugar de UsuarioSid = ''. #>
    param([Parameter(Mandatory)][string]$Origem, [Parameter(Mandatory)][string]$Destino, [Parameter(Mandatory)][string]$UsuarioSid)
    if ($UsuarioSid -notmatch '^S-1-5-21(-\d+){4}$') { throw "SID de usuário fora do formato esperado: $UsuarioSid" }
    $texto = [IO.File]::ReadAllText($Origem, [Text.Encoding]::UTF8)
    $p = Import-PerfilCliente -Caminho $Origem
    if (-not $p.UsuarioSid) {
        $novo = [regex]::Replace($texto, "(?m)^(\s*UsuarioSid\s*=\s*)(''|`"`")", "`${1}'$UsuarioSid'")
        if ($novo -eq $texto) { throw "Perfil sem a linha UsuarioSid = '' para preencher. Informe UsuarioSid no perfil ($UsuarioSid)." }
        $texto = $novo
    }
    [IO.File]::WriteAllText($Destino, $texto, (New-Object Text.UTF8Encoding $true))
    $copia = Import-PerfilCliente -Caminho $Destino
    if ($copia.UsuarioSid -ne $UsuarioSid) { throw "A cópia do perfil tem UsuarioSid $($copia.UsuarioSid), diferente de $UsuarioSid." }
}

function Register-TarefaFluxo {
    <# Tarefa como SYSTEM a cada inicialização, sem limite de tempo (espera logon nas coletas), uma instância por vez. #>
    param([Parameter(Mandatory)][string]$Pasta)
    $menu = Join-Path $Pasta 'src\Menu.ps1'
    $sistema = ([Security.Principal.SecurityIdentifier]'S-1-5-18').Translate([Security.Principal.NTAccount]).Value
    $acao = New-ScheduledTaskAction -Execute $script:PowerShellExe -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Continuar "{1}"' -f $menu, $Pasta)
    $principal = New-ScheduledTaskPrincipal -UserId $sistema -LogonType ServiceAccount -RunLevel Highest
    $cfg = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskPath $script:PastaTarefa -TaskName $script:TarefaFluxo -Action $acao -Trigger (New-ScheduledTaskTrigger -AtStartup) `
        -Principal $principal -Settings $cfg -Force -ErrorAction Stop | Out-Null
}

function Remove-TarefaOtimizacao {
    <# Remove a tarefa indicada e, se ficar vazia, a pasta \Otimizacao\ do Agendador. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Remove só as tarefas criadas por este script.')]
    param([Parameter(Mandatory)][string]$Nome)
    Unregister-ScheduledTask -TaskPath $script:PastaTarefa -TaskName $Nome -Confirm:$false -ErrorAction SilentlyContinue
    try {
        $servico = New-Object -ComObject Schedule.Service
        $servico.Connect()
        $pasta = $servico.GetFolder($script:PastaTarefa.TrimEnd('\'))
        if (-not $pasta.GetTasks(1).Count -and -not $pasta.GetFolders(0).Count) { $servico.GetFolder('\').DeleteFolder($pasta.Name, 0) }
    }
    catch { Write-Verbose "Pasta do Agendador mantida: $($_.Exception.Message)" }
}

function Start-FluxoOtimizacao {
    <#
        Cria a pasta do fluxo (acesso restrito, cópia de src e do perfil), grava o estado e registra a tarefa.
        Não reinicia: o chamador executa Invoke-FluxoOtimizacao em seguida. Retorna a pasta do fluxo.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Chamada só depois da confirmação do menu.')]
    param(
        [Parameter(Mandatory)][string]$PerfilOrigem,
        [Parameter(Mandatory)][string]$UsuarioSid,
        [int]$AguardarUptimeMinutos = 10,
        [int]$AmostraSegundos = 300,
        [string]$Raiz = $script:RaizFluxo
    )
    $p = Import-PerfilCliente -Caminho $PerfilOrigem
    $scripts = Get-ScriptAplicavel -Perfil $p
    if (-not $scripts.Count) { throw 'Nenhum item que altere o sistema no perfil.' }
    if (@(Get-FluxoEmAndamento -Raiz $Raiz).Count) { throw 'Já existe um fluxo em andamento. Cancele-o antes de iniciar outro.' }

    $pasta = Join-Path (Join-Path $Raiz $p.Cliente) ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-Fluxo')
    New-Item -ItemType Directory -Path $pasta -Force | Out-Null
    Set-AcessoRestrito -Pasta $pasta
    $src = New-Item -ItemType Directory -Path (Join-Path $pasta 'src') -Force
    Copy-Item -Path (Join-Path $PSScriptRoot '*') -Include '*.ps1', '*.psm1' -Destination $src.FullName -ErrorAction Stop
    $perfilFluxo = Join-Path $pasta 'perfil.psd1'
    Copy-PerfilFluxo -Origem $PerfilOrigem -Destino $perfilFluxo -UsuarioSid $UsuarioSid

    $estado = [pscustomobject]@{
        Cliente               = $p.Cliente
        Computador            = $env:COMPUTERNAME
        PerfilOrigem          = (Resolve-Path -LiteralPath $PerfilOrigem).Path
        Perfil                = $perfilFluxo
        UsuarioSid            = $UsuarioSid
        IniciadoPor           = "$env:USERDOMAIN\$env:USERNAME"
        Inicio                = (Get-Date).ToString('s')
        Fim                   = $null
        Status                = 'EmAndamento'
        Motivo                = $null
        MensagemExibida       = $false
        Indice                = 0
        Reinicializacoes      = 0
        AguardarUptimeMinutos = $AguardarUptimeMinutos
        AmostraSegundos       = $AmostraSegundos
        Etapas                = @(Get-PlanoFluxo -Scripts $scripts)
    }
    Save-EstadoFluxo -Pasta $pasta -Estado $estado
    Write-RegistroFluxo -Pasta $pasta -Texto "Fluxo criado por $($estado.IniciadoPor) com $($estado.Etapas.Count) etapas: $($scripts -join ', ')."
    Register-TarefaFluxo -Pasta $pasta
    $pasta
}

#endregion

#region Execução das etapas (tarefa agendada, sem interação)

function Get-UsuarioConectado {
    <# Conta conectada ao console, ou vazio. #>
    [string](Get-CimInstance Win32_ComputerSystem).UserName
}

function Wait-Logon {
    <# Espera alguém entrar no Windows. Retorna $false se o fluxo for cancelado durante a espera. #>
    param([Parameter(Mandatory)][string]$Pasta, [int]$IntervaloSegundos = 15)
    while (-not (Get-UsuarioConectado)) {
        if ((Get-EstadoFluxo -Pasta $Pasta).Status -ne 'EmAndamento') { return $false }
        Start-Sleep -Seconds $IntervaloSegundos
    }
    $true
}

function Restart-Fluxo {
    <# Reinicia com aviso quando há alguém conectado. shutdown.exe existe em todas as edições. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Etapa do fluxo confirmado no menu.')]
    param([Parameter(Mandatory)][string]$Pasta)
    $segundos = if (Get-UsuarioConectado) { $script:AvisoReinicioSegundos } else { 0 }
    Write-RegistroFluxo -Pasta $Pasta -Texto "Reiniciando em $segundos s."
    # /d p:4:1 = planejado, manutenção de aplicativo (motivo registrado no log de eventos).
    & "$env:windir\System32\shutdown.exe" /r /t $segundos /d p:4:1 /c 'Otimização em andamento: o computador vai reiniciar. Salve seus arquivos.' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "shutdown.exe falhou (código $LASTEXITCODE)." }
}

function Invoke-ProcessoEtapa {
    <# Executa um .ps1 num processo PowerShell 5.1 separado, grava a saída (UTF-8) e retorna o código de saída. #>
    param([Parameter(Mandatory)][string]$Arquivo, [string[]]$Argumentos = @(), [Parameter(Mandatory)][string]$Saida)
    $ErrorActionPreference = 'Continue'
    $linhas = @(& $script:PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $Arquivo @Argumentos 2>&1 | ForEach-Object { "$_" })
    $codigo = $LASTEXITCODE
    [IO.File]::WriteAllLines($Saida, [string[]]$linhas, (New-Object Text.UTF8Encoding $true))
    $codigo
}

function Get-FimSaida {
    <# Últimas linhas não vazias de uma saída de etapa, para o motivo da mensagem. #>
    param([string]$Arquivo, [int]$Linhas = 6)
    if (-not $Arquivo -or -not (Test-Path -LiteralPath $Arquivo)) { return '' }
    (@([IO.File]::ReadAllLines($Arquivo, [Text.Encoding]::UTF8) | Where-Object { $_.Trim() }) | Select-Object -Last $Linhas) -join [Environment]::NewLine
}

function Get-AchadoManutencao {
    <# Achados (linhas Info com "ATENÇÃO:") da sessão de Manutencao mais recente criada a partir de Desde. #>
    param([Parameter(Mandatory)][string]$Cliente, [Parameter(Mandatory)][datetime]$Desde, [string]$Raiz = $script:RaizFluxo)
    $sessao = Get-ChildItem -LiteralPath (Join-Path $Raiz $Cliente) -Directory -Filter '*-Manutencao' -ErrorAction SilentlyContinue |
        Where-Object { $_.CreationTime -ge $Desde.AddSeconds(-5) } | Sort-Object -Property Name | Select-Object -Last 1
    if (-not $sessao) { return @() }
    $log = Join-Path $sessao.FullName 'log.csv'
    if (-not (Test-Path -LiteralPath $log)) { return @() }
    @(Import-Csv -LiteralPath $log -Encoding UTF8 | Where-Object { $_.Resultado -eq 'Info' -and $_.Detalhe -like 'ATENÇÃO:*' } |
            ForEach-Object { "[$($_.Item)] $($_.Alvo): $($_.Detalhe.Substring(9).Trim())" })
}

function Invoke-EtapaFluxo {
    <#
        Executa uma etapa e devolve a decisão: Seguir (próxima etapa), Reiniciar (o boot seguinte continua) ou Parar (com
        Motivo). Atualiza Status, Detalhe e Arquivo da etapa; o chamador grava o estado.
    #>
    param([Parameter(Mandatory)]$Estado, [Parameter(Mandatory)]$Etapa, [Parameter(Mandatory)][string]$Pasta)
    $numero = [int]$Estado.Indice + 1
    $src = Join-Path $Pasta 'src'
    $saida = Join-Path $Pasta ('etapa-{0:D2}-{1}.txt' -f $numero, ($Etapa.Nome -replace '[^\w]+', '-').Trim('-'))
    $decisao = { param($Acao, $Motivo) [pscustomobject]@{ Acao = $Acao; Motivo = $Motivo } }

    switch ($Etapa.Tipo) {
        'Reiniciar' {
            $Etapa.Status = 'OK'
            return & $decisao 'Reiniciar' $null
        }
        'Coleta' {
            if (-not (Wait-Logon -Pasta $Pasta)) { return & $decisao 'Parar' 'Fluxo cancelado.' }
            $destino = Join-Path $Pasta "coleta-$($Etapa.Rotulo)"
            New-Item -ItemType Directory -Path $destino -Force | Out-Null
            $codigo = Invoke-ProcessoEtapa -Arquivo (Join-Path $src 'Coleta.ps1') -Saida $saida -Argumentos @(
                '-UsuarioSid', $Estado.UsuarioSid, '-AguardarUptimeMinutos', [string]$Estado.AguardarUptimeMinutos,
                '-AmostraSegundos', [string]$Estado.AmostraSegundos, '-PastaSaida', $destino)
            $json = Get-ChildItem -LiteralPath $destino -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object -Property LastWriteTime | Select-Object -Last 1
            if (-not $json) { $Etapa.Status = 'Falha'; $Etapa.Arquivo = $saida; return & $decisao 'Parar' "A $($Etapa.Nome) não gerou o arquivo de resultado (código $codigo)." }
            $Etapa.Arquivo = $json.FullName
            $Etapa.Status = 'OK'
            return & $decisao 'Seguir' $null
        }
        'Script' {
            if ((Test-ReinicializacaoPendente).PSObject.Properties.Value -contains $true) {
                if ([int]$Etapa.Tentativas -ge $script:MaxReinicioPendente) {
                    $Etapa.Status = 'Falha'
                    return & $decisao 'Parar' "Reinicialização pendente continua depois de $($script:MaxReinicioPendente) reinicializações (Windows Update ou instalação em andamento)."
                }
                $Etapa.Tentativas = [int]$Etapa.Tentativas + 1
                $Etapa.Detalhe = 'Reinicialização pendente: reiniciando antes do script.'
                return & $decisao 'Reiniciar' $null
            }
            $inicio = Get-Date
            $codigo = Invoke-ProcessoEtapa -Arquivo (Join-Path $src "$($Etapa.Nome).ps1") -Argumentos @('-Perfil', $Estado.Perfil) -Saida $saida
            $Etapa.Arquivo = $saida
            if ($codigo -ne 0) { $Etapa.Status = 'Falha'; return & $decisao 'Parar' "$($Etapa.Nome) terminou com erro (código $codigo)." }
            if ($Etapa.Nome -eq 'Manutencao') {
                $achados = @(Get-AchadoManutencao -Cliente $Estado.Cliente -Desde $inicio)
                if ($achados.Count) {
                    $Etapa.Status = 'Falha'
                    return & $decisao 'Parar' ("A Manutencao encontrou problema que precisa ser resolvido antes de otimizar: " + ($achados -join ' | '))
                }
            }
            $Etapa.Status = 'OK'
            return & $decisao 'Seguir' $null
        }
        'Comparar' {
            $coletas = @(@($Estado.Etapas) | Where-Object { $_.Tipo -eq 'Coleta' })
            $antes = @($coletas | Where-Object { $_.Rotulo -like 'antes*' } | ForEach-Object { $_.Arquivo })
            $depois = ($coletas | Where-Object { $_.Rotulo -eq 'depois' }).Arquivo
            $html = Join-Path $Pasta 'comparacao.html'
            $codigo = Invoke-ProcessoEtapa -Arquivo (Join-Path $src 'Coleta.ps1') -Saida $saida -Argumentos @('-Comparar', '-Antes', ($antes -join ','), '-Depois', $depois, '-SaidaHtml', $html)
            # Comparação é só leitura: sem ela a verificação ainda vale, então o fluxo segue.
            if (Test-Path -LiteralPath $html) { $Etapa.Arquivo = $html; $Etapa.Status = 'OK' }
            else { $Etapa.Status = 'Falha'; $Etapa.Detalhe = "Comparação não gerada (código $codigo). Ver $saida." }
            return & $decisao 'Seguir' $null
        }
        'Verificar' {
            $relatorio = Join-Path $Pasta 'verificacao.txt'
            $codigo = Invoke-ProcessoEtapa -Arquivo (Join-Path $src 'Verificacao.ps1') -Argumentos @('-Perfil', $Estado.Perfil, '-Relatorio', $relatorio) -Saida $saida
            if (Test-Path -LiteralPath $relatorio) { $Etapa.Arquivo = $relatorio; $Etapa.Status = 'OK' }
            else { $Etapa.Status = 'Falha'; $Etapa.Detalhe = "Verificação não concluída (código $codigo). Ver $saida." }
            return & $decisao 'Seguir' $null
        }
        default { throw "Tipo de etapa desconhecido: $($Etapa.Tipo)." }
    }
}

function Get-TextoMensagem {
    <# Mensagem final em linguagem simples: resultado da verificação (concluído) ou motivo da interrupção. #>
    param([Parameter(Mandatory)]$Estado, [Parameter(Mandatory)][string]$Pasta)
    $etapas = @($Estado.Etapas)
    $l = New-Object System.Collections.Generic.List[string]
    $quando = '{0} a {1}' -f ([datetime]$Estado.Inicio).ToString('dd/MM/yyyy HH:mm'), (Get-Date).ToString('dd/MM/yyyy HH:mm')
    if ($Estado.Status -eq 'Concluido') {
        $l.Add("Otimização concluída no computador $($Estado.Computador) (cliente $($Estado.Cliente)).")
        $l.Add("Período: $quando. Reinicializações: $($Estado.Reinicializacoes).")
        $l.Add('')
        $verificacao = ($etapas | Where-Object { $_.Tipo -eq 'Verificar' }).Arquivo
        if ($verificacao -and (Test-Path -LiteralPath $verificacao)) { foreach ($x in [IO.File]::ReadAllLines($verificacao, [Text.Encoding]::UTF8)) { $l.Add($x) } }
        else { $l.Add('A verificação final não foi concluída. ' + ($etapas | Where-Object { $_.Tipo -eq 'Verificar' }).Detalhe) }
        $l.Add('')
        $comparar = $etapas | Where-Object { $_.Tipo -eq 'Comparar' }
        if ($comparar.Status -eq 'OK') { $l.Add("Desempenho antes e depois (abrir no navegador): $($comparar.Arquivo)") }
        else { $l.Add("Comparação de desempenho não gerada. $($comparar.Detalhe)") }
    }
    else {
        $atual = $etapas[[int]$Estado.Indice]
        $l.Add("A otimização foi interrompida no computador $($Estado.Computador) (cliente $($Estado.Cliente)).")
        $l.Add("Etapa $([int]$Estado.Indice + 1) de $($etapas.Count): $($atual.Nome).")
        $l.Add("Motivo: $($Estado.Motivo)")
        $l.Add("Período: $quando. Reinicializações: $($Estado.Reinicializacoes).")
        $l.Add('')
        $feitas = @($etapas | Where-Object { $_.Status -eq 'OK' -and $_.Tipo -eq 'Script' } | ForEach-Object { $_.Nome })
        $l.Add($(if ($feitas.Count) { "Scripts concluídos antes da interrupção: $($feitas -join ', '). O que eles aplicaram continua aplicado." } else { 'Nenhum script de otimização chegou a ser concluído.' }))
        $l.Add('Nada mais foi executado depois da interrupção.')
        $fim = Get-FimSaida -Arquivo $atual.Arquivo
        if ($fim) { $l.Add(''); $l.Add('Final da saída da etapa:'); foreach ($x in $fim -split [Environment]::NewLine) { $l.Add("  $x") } }
        $l.Add('')
        $l.Add('Para desfazer o que foi aplicado: abra o Menu como administrador e escolha Reverter.')
    }
    $l.Add("Arquivos do fluxo: $Pasta")
    $l.ToArray()
}

function Show-MensagemUsuario {
    <#
        Abre a mensagem no Bloco de Notas na sessão do usuário conectado: a tarefa roda como SYSTEM (sessão 0, sem tela),
        então registra uma tarefa temporária no nome do usuário (logon interativo, sem senha), inicia e remove.
    #>
    param([Parameter(Mandatory)][string]$Arquivo, [Parameter(Mandatory)][string]$Pasta)
    if (-not (Wait-Logon -Pasta $Pasta)) { return }
    $usuario = Get-UsuarioConectado
    $acao = New-ScheduledTaskAction -Execute (Join-Path $env:windir 'System32\notepad.exe') -Argument "`"$Arquivo`""
    $principal = New-ScheduledTaskPrincipal -UserId $usuario -LogonType Interactive -RunLevel Limited
    $cfg = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskPath $script:PastaTarefa -TaskName $script:TarefaMensagem -Action $acao -Principal $principal -Settings $cfg -Force -ErrorAction Stop | Out-Null
    try {
        Start-ScheduledTask -TaskPath $script:PastaTarefa -TaskName $script:TarefaMensagem -ErrorAction Stop
        $limite = (Get-Date).AddSeconds(30)
        do { Start-Sleep -Seconds 2; $info = Get-ScheduledTaskInfo -TaskPath $script:PastaTarefa -TaskName $script:TarefaMensagem }
        while ($info.LastRunTime -lt (Get-Date).AddMinutes(-1) -and (Get-Date) -lt $limite)
        Write-RegistroFluxo -Pasta $Pasta -Texto "Mensagem aberta para $usuario (última execução $($info.LastRunTime), resultado $($info.LastTaskResult))."
    }
    finally { Remove-TarefaOtimizacao -Nome $script:TarefaMensagem }
}

function Complete-Fluxo {
    <#
        Encerra o fluxo: grava estado e mensagem, abre a mensagem para o usuário conectado (espera logon) e por último
        remove a tarefa. Se o PC reiniciar antes de alguém entrar, a tarefa ainda existe e o boot seguinte mostra a mensagem.
    #>
    param([Parameter(Mandatory)]$Estado, [Parameter(Mandatory)][string]$Pasta, [Parameter(Mandatory)][ValidateSet('Concluido', 'Interrompido')][string]$Status, [string]$Motivo)
    $Estado.Status = $Status
    $Estado.Motivo = $Motivo
    $Estado.Fim = (Get-Date).ToString('s')
    Save-EstadoFluxo -Pasta $Pasta -Estado $Estado
    Write-RegistroFluxo -Pasta $Pasta -Texto "Fluxo $Status. $Motivo"
    [IO.File]::WriteAllLines((Join-Path $Pasta 'mensagem.txt'), [string[]](Get-TextoMensagem -Estado $Estado -Pasta $Pasta), (New-Object Text.UTF8Encoding $true))
    Show-MensagemPendente -Estado $Estado -Pasta $Pasta
}

function Show-MensagemPendente {
    <# Abre mensagem.txt se ainda não foi aberta, marca no estado e remove a tarefa do fluxo (última ação). #>
    param([Parameter(Mandatory)]$Estado, [Parameter(Mandatory)][string]$Pasta)
    if (-not $Estado.MensagemExibida) {
        Show-MensagemUsuario -Arquivo (Join-Path $Pasta 'mensagem.txt') -Pasta $Pasta
        $Estado.MensagemExibida = $true
        Save-EstadoFluxo -Pasta $Pasta -Estado $Estado
    }
    Remove-TarefaOtimizacao -Nome $script:TarefaFluxo
}

function Invoke-FluxoOtimizacao {
    <# Executa as etapas a partir da atual até concluir, reiniciar ou parar. Chamado pela tarefa a cada boot. #>
    param([Parameter(Mandatory)][string]$Pasta)
    # Saída UTF-8 entre este processo e os filhos (acentos nas saídas gravadas). Sem console, segue com o padrão.
    try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false } catch { Write-Verbose 'Console sem codificação ajustável.' }
    $estado = Get-EstadoFluxo -Pasta $Pasta
    if ($estado.Status -in 'Concluido', 'Interrompido') { return Show-MensagemPendente -Estado $estado -Pasta $Pasta }
    if ($estado.Status -ne 'EmAndamento') { Remove-TarefaOtimizacao -Nome $script:TarefaFluxo; return }
    Write-RegistroFluxo -Pasta $Pasta -Texto "Retomando na etapa $([int]$estado.Indice + 1) como $env:USERDOMAIN\$env:USERNAME."
    try {
        while ([int]$estado.Indice -lt @($estado.Etapas).Count) {
            # Relê o estado: o menu pode ter cancelado o fluxo enquanto a etapa anterior rodava.
            $estado = Get-EstadoFluxo -Pasta $Pasta
            if ($estado.Status -ne 'EmAndamento') { Write-RegistroFluxo -Pasta $Pasta -Texto "Fluxo $($estado.Status): parado."; Remove-TarefaOtimizacao -Nome $script:TarefaFluxo; return }
            $etapa = @($estado.Etapas)[[int]$estado.Indice]
            $etapa.Status = 'Executando'
            $etapa.Inicio = (Get-Date).ToString('s')
            Save-EstadoFluxo -Pasta $Pasta -Estado $estado
            Write-RegistroFluxo -Pasta $Pasta -Texto "Etapa $([int]$estado.Indice + 1): $($etapa.Nome)."

            $r = Invoke-EtapaFluxo -Estado $estado -Etapa $etapa -Pasta $Pasta
            $etapa.Fim = (Get-Date).ToString('s')
            switch ($r.Acao) {
                'Seguir' { $estado.Indice = [int]$estado.Indice + 1; Save-EstadoFluxo -Pasta $Pasta -Estado $estado }
                'Reiniciar' {
                    if ($etapa.Status -eq 'OK') { $estado.Indice = [int]$estado.Indice + 1 }
                    $estado.Reinicializacoes = [int]$estado.Reinicializacoes + 1
                    Save-EstadoFluxo -Pasta $Pasta -Estado $estado
                    Restart-Fluxo -Pasta $Pasta
                    return
                }
                'Parar' { return Complete-Fluxo -Estado $estado -Pasta $Pasta -Status Interrompido -Motivo $r.Motivo }
            }
        }
        Complete-Fluxo -Estado $estado -Pasta $Pasta -Status Concluido
    }
    catch {
        Write-RegistroFluxo -Pasta $Pasta -Texto "Erro: $($_.Exception.Message)"
        # Erro ao encerrar (mensagem): o estado já está gravado e o próximo boot tenta mostrar a mensagem de novo.
        if ($estado.Status -eq 'EmAndamento') { Complete-Fluxo -Estado $estado -Pasta $Pasta -Status Interrompido -Motivo "Erro inesperado no fluxo: $($_.Exception.Message)" }
    }
}

#endregion

#region Menu (interativo)

function Read-Opcao {
    param([string]$Pergunta)
    Read-Host $Pergunta
}

function Invoke-ScriptConsole {
    <# Executa um script num processo separado, com a saída direto na tela. #>
    param([Parameter(Mandatory)][string]$Arquivo, [string[]]$Argumentos = @())
    & $script:PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $Arquivo @Argumentos
}

function Get-SessaoPendente {
    <# Script tem sessão de aplicação ainda não revertida (mesmo critério do -Revert). #>
    param([Parameter(Mandatory)][string]$Cliente, [Parameter(Mandatory)][string]$Script, [string]$Raiz = $script:RaizFluxo)
    [bool]@(Get-ChildItem -LiteralPath (Join-Path $Raiz $Cliente) -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "*-$Script" -and -not (Test-Path -LiteralPath (Join-Path $_.FullName 'revertido.txt')) }).Count
}

function Invoke-Simulacao {
    param([Parameter(Mandatory)][string]$Perfil, [Parameter(Mandatory)][string[]]$Scripts)
    foreach ($s in $Scripts) {
        Write-Host ''
        Write-Host "===== Simulação: $s =====" -ForegroundColor Cyan
        Invoke-ScriptConsole -Arquivo (Join-Path $PSScriptRoot "$s.ps1") -Argumentos @('-Perfil', $Perfil, '-WhatIf')
    }
}

function Resolve-UsuarioFluxo {
    <# SID do usuário alvo para o fluxo: o do perfil ou, vazio, o do usuário conectado agora. #>
    param([Parameter(Mandatory)]$Perfil)
    $alvo = Get-UsuarioAlvo -Sid $Perfil.UsuarioSid
    $nome = try { ([Security.Principal.SecurityIdentifier]$alvo.Sid).Translate([Security.Principal.NTAccount]).Value } catch { $alvo.Sid }
    [pscustomobject]@{ Sid = $alvo.Sid; Nome = $nome; DoPerfil = [bool]$Perfil.UsuarioSid }
}

function Start-FluxoMenu {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Simula e pede confirmação (S/N) antes de alterar.')]
    param([Parameter(Mandatory)][string]$CaminhoPerfil, [Parameter(Mandatory)]$Perfil)
    $scripts = Get-ScriptAplicavel -Perfil $Perfil
    if (-not $scripts.Count) { Write-Host 'Nenhum item que altere o sistema no perfil.' -ForegroundColor Yellow; return }
    $pre = Test-PreCondicao -PermitirReinicializacaoPendente
    foreach ($a in $pre.Avisos) { Write-Host "Aviso: $a" -ForegroundColor Yellow }
    if ($pre.Bloqueios.Count) {
        foreach ($b in $pre.Bloqueios) { Write-Host "Bloqueio: $b" -ForegroundColor Red }
        Write-Host 'Resolva os bloqueios e tente de novo. Nada foi alterado.' -ForegroundColor Red
        return
    }
    try { $u = Resolve-UsuarioFluxo -Perfil $Perfil }
    catch { Write-Host "Usuário alvo: $($_.Exception.Message) Preencha UsuarioSid no perfil." -ForegroundColor Red; return }

    Invoke-Simulacao -Perfil $CaminhoPerfil -Scripts $scripts

    Write-Host ''
    Write-Host '===== Fluxo completo =====' -ForegroundColor Cyan
    Write-Host "Cliente: $($Perfil.Cliente)   Usuário alvo: $($u.Nome)$(if (-not $u.DoPerfil) { ' (usuário conectado agora; UsuarioSid vazio no perfil)' })"
    $n = 0
    foreach ($e in Get-PlanoFluxo -Scripts $scripts) { $n++; Write-Host ('  {0,2}. {1}' -f $n, $e.Nome) }
    Write-Host ''
    Write-Host 'Durante o fluxo:'
    Write-Host '  - Nas três coletas, entre com o usuário do cliente logo depois de reiniciar e deixe o PC parado até ele reiniciar sozinho.'
    Write-Host '  - A otimização roda na tela de entrada, sem ninguém conectado. Não é preciso entrar.'
    Write-Host '  - Com alguém conectado, o aviso de reinicialização aparece 60 segundos antes.'
    Write-Host '  - A Proteção do Sistema precisa estar ligada no disco do sistema: cada script cria um ponto de restauração.'
    Write-Host '  - Duração estimada: 1 h 30 a 2 h. No fim, o resultado abre no Bloco de Notas.'
    Write-Host ''
    if ((Read-Opcao 'Confirmar e iniciar o fluxo? Depois disto nada mais será perguntado (S/N)') -notmatch '^[sS]$') { Write-Host 'Cancelado. Nada foi alterado.'; return }

    $pasta = Start-FluxoOtimizacao -PerfilOrigem $CaminhoPerfil -UsuarioSid $u.Sid
    Write-Host "Fluxo iniciado. Pasta: $pasta" -ForegroundColor Green
    Write-Host "O computador vai reiniciar em $($script:AvisoReinicioSegundos) segundos. Depois disso, siga as instruções acima." -ForegroundColor Green
    Invoke-FluxoOtimizacao -Pasta $pasta
}

function Start-ReversaoMenu {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Simula e pede confirmação (S/N) antes de alterar.')]
    param([Parameter(Mandatory)][string]$CaminhoPerfil, [Parameter(Mandatory)]$Perfil)
    $ordem = @($script:Scripts | ForEach-Object { $_.Nome })
    [array]::Reverse($ordem)
    $pendentes = @($ordem | Where-Object { Get-SessaoPendente -Cliente $Perfil.Cliente -Script $_ })
    if (-not $pendentes.Count) { Write-Host "Nada a reverter para o cliente $($Perfil.Cliente)."; return }
    foreach ($s in $pendentes) {
        Write-Host ''
        Write-Host "===== Simulação da reversão: $s =====" -ForegroundColor Cyan
        Invoke-ScriptConsole -Arquivo (Join-Path $PSScriptRoot "$s.ps1") -Argumentos @('-Perfil', $CaminhoPerfil, '-Revert', '-WhatIf')
    }
    Write-Host ''
    if ((Read-Opcao "Reverter $($pendentes -join ', ') nesta ordem? (S/N)") -notmatch '^[sS]$') { Write-Host 'Cancelado. Nada foi alterado.'; return }
    foreach ($s in $pendentes) {
        Write-Host ''
        Write-Host "===== Reversão: $s =====" -ForegroundColor Cyan
        Invoke-ScriptConsole -Arquivo (Join-Path $PSScriptRoot "$s.ps1") -Argumentos @('-Perfil', $CaminhoPerfil, '-Revert')
    }
    Write-Host ''
    Write-Host 'Reversão concluída. Reinicie o computador para que tudo volte a valer.' -ForegroundColor Green
}

function Stop-FluxoMenu {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Pede confirmação (S/N) antes de cancelar.')]
    param([Parameter(Mandatory)]$Fluxo)
    if ((Read-Opcao 'Cancelar o fluxo em andamento? (S/N)') -notmatch '^[sS]$') { return }
    $Fluxo.Estado.Status = 'Cancelado'
    $Fluxo.Estado.Fim = (Get-Date).ToString('s')
    Save-EstadoFluxo -Pasta $Fluxo.Pasta -Estado $Fluxo.Estado
    Write-RegistroFluxo -Pasta $Fluxo.Pasta -Texto "Cancelado no menu por $env:USERDOMAIN\$env:USERNAME."
    Remove-TarefaOtimizacao -Nome $script:TarefaFluxo
    Write-Host 'Fluxo cancelado. Se uma etapa estiver em execução, ela termina e nada mais é executado. O que já foi aplicado continua; para desfazer, use Reverter.' -ForegroundColor Yellow
}

function Get-PastaPerfil {
    <# Pastas de perfis: os gerados pelo Novo perfil (na máquina, nunca no repositório) e perfis\ do projeto. #>
    Join-Path $script:RaizFluxo 'perfis'
    Join-Path (Split-Path -Parent $PSScriptRoot) 'perfis'
}

function Get-ArquivoPerfil {
    <# Perfis .psd1 das pastas de perfis, sem o exemplo do projeto, por nome. #>
    @(foreach ($p in Get-PastaPerfil) { Get-ChildItem -LiteralPath $p -Filter '*.psd1' -File -ErrorAction SilentlyContinue }) |
        Where-Object { $_.Name -ne 'exemplo.psd1' } | Sort-Object -Property Name
}

function Select-PerfilMenu {
    <# Lista os perfis e a opção Novo perfil; devolve o escolhido ou o criado (Caminho e Perfil), ou $null para sair. #>
    while ($true) {
        $arquivos = @(Get-ArquivoPerfil)
        Write-Host ''
        Write-Host 'Perfis de cliente:' -ForegroundColor Cyan
        for ($i = 0; $i -lt $arquivos.Count; $i++) { Write-Host ('  {0}. {1}' -f ($i + 1), $arquivos[$i].Name) }
        Write-Host '  N. Novo perfil'
        Write-Host '  0. Sair'
        $op = Read-Opcao 'Perfil'
        if ($op -eq '0') { return $null }
        if ($op -match '^[nN]$') {
            $pasta = @(Get-PastaPerfil)[0]
            if (-not (Test-Path -LiteralPath $pasta)) { New-Item -ItemType Directory -Path $pasta -Force | Out-Null; Set-AcessoRestrito -Pasta $pasta }
            # Carregado só aqui: o fluxo no boot não precisa das funções de leitura do Novo perfil.
            try {
                . (Join-Path $PSScriptRoot 'Perfil.ps1')
                $novo = New-PerfilInterativo -Pasta $pasta
                if ($novo) { return [pscustomobject]@{ Caminho = $novo; Perfil = Import-PerfilCliente -Caminho $novo } }
            }
            catch { Write-Host "Novo perfil interrompido: $($_.Exception.Message)" -ForegroundColor Red }
            continue
        }
        $n = 0
        if ([int]::TryParse($op, [ref]$n) -and $n -ge 1 -and $n -le $arquivos.Count) {
            try { return [pscustomobject]@{ Caminho = $arquivos[$n - 1].FullName; Perfil = Import-PerfilCliente -Caminho $arquivos[$n - 1].FullName } }
            catch { Write-Host $_.Exception.Message -ForegroundColor Red }
        }
    }
}

function Show-MenuPrincipal {
    if (-not (Test-Administrador)) { throw 'Execute o Menu como administrador (botão direito no PowerShell, Executar como administrador).' }
    while ($true) {
        $andamento = @(Get-FluxoEmAndamento)
        if ($andamento.Count) {
            $f = $andamento[0]
            $etapas = @($f.Estado.Etapas)
            Write-Host ''
            Write-Host "Fluxo em andamento: cliente $($f.Estado.Cliente), etapa $([int]$f.Estado.Indice + 1) de $($etapas.Count) ($($etapas[[int]$f.Estado.Indice].Nome))." -ForegroundColor Yellow
            Write-Host "Pasta: $($f.Pasta)"
            Write-Host '  5. Cancelar o fluxo em andamento'
            Write-Host '  0. Sair'
            switch (Read-Opcao 'Opção') { '5' { Stop-FluxoMenu -Fluxo $f } '0' { return } }
            continue
        }
        $escolha = Select-PerfilMenu
        if (-not $escolha) { return }
        Write-Host ''
        Write-Host "Cliente: $($escolha.Perfil.Cliente)   Itens: $(@($escolha.Perfil.Aplicar | Where-Object { $escolha.Perfil.Pular -notcontains $_ }) -join ', ')" -ForegroundColor Cyan
        Write-Host '  1. Simular (nada é alterado)'
        Write-Host '  2. Fluxo completo (coletas, otimização, reinicializações e verificação, sozinho)'
        Write-Host '  3. Só verificar agora'
        Write-Host '  4. Reverter'
        Write-Host '  0. Voltar'
        switch (Read-Opcao 'Opção') {
            '1' { Invoke-Simulacao -Perfil $escolha.Caminho -Scripts (Get-ScriptAplicavel -Perfil $escolha.Perfil) }
            '2' { Start-FluxoMenu -CaminhoPerfil $escolha.Caminho -Perfil $escolha.Perfil; if (@(Get-FluxoEmAndamento).Count) { return } }
            '3' { Invoke-ScriptConsole -Arquivo (Join-Path $PSScriptRoot 'Verificacao.ps1') -Argumentos @('-Perfil', $escolha.Caminho) }
            '4' { Start-ReversaoMenu -CaminhoPerfil $escolha.Caminho -Perfil $escolha.Perfil }
        }
    }
}

#endregion

# Permite carregar as funções com dot-source (testes) sem executar.
if ($MyInvocation.InvocationName -ne '.') {
    if ($Continuar) { Invoke-FluxoOtimizacao -Pasta $Continuar }
    else { Show-MenuPrincipal }
}
