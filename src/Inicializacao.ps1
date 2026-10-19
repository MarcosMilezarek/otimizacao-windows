<#
.SYNOPSIS
    Inicialização e segundo plano (itens I1 a I12 do catálogo) conforme o perfil do cliente.

.DESCRIPTION
    Aplica somente os itens I* listados em Aplicar no perfil e não listados em Pular. Nada é excluído: entradas,
    tarefas e serviços são desabilitados, com o estado original salvo. Valores já definidos por política são pulados.
      I1  Desabilita entradas de inicialização listadas em Opcoes.I1Desabilitar (nome da entrada como na Coleta), pelo
          mesmo mecanismo do Gerenciador de Tarefas (Explorer\StartupApproved, primeiro byte com bit 0 ligado).
          Nunca desabilita componente do Windows (executável em %windir%) nem nome em Protegidos.Inicializacao.
      I2  Edge: StartupBoostEnabled=0 e BackgroundModeEnabled=0 (políticas do Edge). Só com o Edge instalado.
      I3  Chrome: BackgroundModeEnabled=0 (política do Chrome). Só com o Chrome instalado.
      I4  Nega execução em segundo plano aos apps da Store listados em Opcoes.I4NegarSegundoPlano (Package Family
          Name), pela política LetAppsRunInBackground_ForceDenyTheseApps (AppPrivacy.admx). Nunca para todos os apps.
      I5  Widgets desligados: AllowNewsAndInterests=0 (Windows 11). Pulado com o driver UCPD em execução: ele bloqueia
          gravar e apagar essa política fora das ferramentas da Microsoft (orientação no log: Configurações).
      I6  Remove o app Microsoft Copilot de consumidor (pacote Microsoft.Copilot) de todos os usuários e da imagem.
          Não toca no Microsoft 365 Copilot (Microsoft.MicrosoftOfficeHub).
      I7  DisableSearchBoxSuggestions=1 no usuário alvo. CONFIANÇA BAIXA: documentado para a caixa de busca do
          Explorer; o efeito de tirar a web da busca do Iniciar vem de fontes de terceiros. Conferir no cliente.
      I8  Gravação em segundo plano do Game Bar desligada: AllowGameDVR=0 (GameDVR.admx).
      I9  Desabilita tarefas agendadas de terceiros listadas em Opcoes.I9Tarefas ('\Pasta\Nome'). Recusa tarefas
          em \Microsoft\ e nomes em Protegidos.Tarefas.
      I10 Tipo de início de serviços de terceiros em Opcoes.I10Servicos (@{ Nome = 'Manual' ou 'Disabled' }). Recusa
          serviços com executável em %windir% e nomes em Protegidos.Servicos. Não para o serviço: vale após reiniciar.
      I11 Sugestões de terceiros desligadas (DisableThirdPartySuggestions, usuário alvo). Em Enterprise e Education,
          também DisableWindowsConsumerFeatures e DisableSoftLanding (valem só nessas edições, Experience CSP).
      I12 Recall sem snapshots (DisableAIDataAnalysis=1) e Click to Do desligado (DisableClickToDo=1). Só se o
          componente Recall existir com conteúdo (PCs Copilot+); com DisabledWithPayloadRemoved é pulado.

    Fontes: learn.microsoft.com (DeployEdge StartupBoostEnabled e BackgroundModeEnabled; Policy CSP NewsAndInterests,
    WindowsAI, Experience e Privacy; answers/a/12414137 para o pacote do Copilot), DISA STIG V-221570 (Chrome),
    ADMX em %windir%\PolicyDefinitions (AppPrivacy, GameDVR, WindowsExplorer).

.PARAMETER Perfil
    Arquivo .psd1 do cliente.

.PARAMETER Revert
    Reverte todas as sessões de aplicação ainda não revertidas, da mais recente para a mais antiga (ou só a indicada
    em -Sessao): valores de registro, estado das tarefas e tipo de início dos serviços voltam ao original.

.PARAMETER Sessao
    Pasta da sessão a reverter.

.PARAMETER PermitirReinicializacaoPendente
    Não bloqueia a execução quando há reinicialização pendente.

.EXAMPLE
    .\Inicializacao.ps1 -Perfil .\perfis\ClienteX.psd1 -WhatIf

.EXAMPLE
    .\Inicializacao.ps1 -Perfil .\perfis\ClienteX.psd1 -Revert

.NOTES
    O que se perde: I1 e I9 fazem o programa ou a tarefa não iniciar sozinhos; I2 deixa o Edge cerca de 1 s mais
    lento para abrir; I3 e I4 cortam notificações com o app fechado; I5 tira o painel de widgets; I6 remove o app
    Copilot; I7 tira resultados da web do Iniciar (se tiver efeito); I8 tira a gravação do Game Bar; I10 faz o serviço
    não iniciar sozinho; I11 tira sugestões e dicas; I12 desliga Recall e Click to Do.
    Reversão: -Revert restaura tudo, exceto I6: o app Copilot volta só reinstalando pela Microsoft Store.
    Na simulação podem aparecer linhas "What if" de módulos do Windows: são internas e não alteram o sistema.
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Aplicar')]
param(
    [Parameter(Mandatory)]
    [string]$Perfil,

    [Parameter(ParameterSetName = 'Reverter', Mandatory)]
    [switch]$Revert,

    [Parameter(ParameterSetName = 'Reverter')]
    [string]$Sessao,

    [switch]$PermitirReinicializacaoPendente
)

Import-Module (Join-Path $PSScriptRoot 'Otimizacao.Comum.psm1') -Force

$script:NomeScript = 'Inicializacao'
$script:HKLM = 'Registry::HKEY_LOCAL_MACHINE'
$script:PacoteCopilot = 'Microsoft.Copilot'
$script:MotivoI5Ucpd = 'Bloqueado pelo Windows (driver UCPD em execução). Ocultar no usuário do cliente: Configurações > Personalização > Barra de tarefas > Widgets.'

#region Auxiliares

function Get-Opcao {
    param($Perfil, [string]$Nome)
    if ($Perfil.Opcoes -and $Perfil.Opcoes.ContainsKey($Nome)) { $Perfil.Opcoes[$Nome] } else { $null }
}

function Get-ExecutavelComando {
    <# Caminho do executável de uma linha de comando (Run, serviço), com variáveis de ambiente expandidas. #>
    param([string]$Comando)
    if (-not $Comando) { return $null }
    $c = [Environment]::ExpandEnvironmentVariables($Comando.Trim())
    if ($c.StartsWith('"')) {
        $fim = $c.IndexOf('"', 1)
        if ($fim -gt 1) { return $c.Substring(1, $fim - 1) }
    }
    $m = [regex]::Match($c, '^(.+?\.(exe|com|bat|cmd|lnk))(\s|$)', 'IgnoreCase')
    if ($m.Success) { $m.Groups[1].Value } else { ($c -split '\s+')[0] }
}

function Test-ComponenteWindows {
    <# Verdadeiro se o executável fica em %windir% (componente do Windows: nunca desabilitado por este script). #>
    param([string]$Comando)
    $exe = Get-ExecutavelComando $Comando
    [bool]($exe -and $exe.StartsWith($env:windir, [StringComparison]::OrdinalIgnoreCase))
}

function Test-AppInstalado {
    param([string]$Executavel)
    Test-Path -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$Executavel"
}

#endregion

#region I1 Entradas de inicialização

function Get-FonteInicializacao {
    <#
        Entradas de inicialização com a chave StartupApproved correspondente.
        Escopo Maquina: Raiz = HKLM. Escopo Usuario: Raiz = hive do usuário alvo, PerfilUsuario resolve %USERPROFILE%.
    #>
    param([Parameter(Mandatory)][string]$Raiz, [ValidateSet('Maquina', 'Usuario')][string]$Escopo, [string]$PerfilUsuario)
    $sw = 'SOFTWARE\Microsoft\Windows\CurrentVersion'
    $aprov = "$sw\Explorer\StartupApproved"
    if ($Escopo -eq 'Maquina') {
        $runs = @(
            @{ Origem = 'Maquina\Run'; Run = "$sw\Run"; Aprov = "$aprov\Run" }
            @{ Origem = 'Maquina\Run32'; Run = 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Aprov = "$aprov\Run32" }
        )
        $pastas = @(@{ Origem = 'Maquina\PastaInicializar'; Pasta = [Environment]::GetFolderPath('CommonStartup'); Aprov = "$aprov\StartupFolder" })
    }
    else {
        $runs = @(@{ Origem = 'Usuario\Run'; Run = "$sw\Run"; Aprov = "$aprov\Run" })
        $pasta = $null
        $usf = Get-Item -LiteralPath "$Raiz\$sw\Explorer\User Shell Folders" -ErrorAction SilentlyContinue
        if ($usf) {
            $bruto = $usf.GetValue('Startup', $null, 'DoNotExpandEnvironmentNames')
            if ($bruto) { $pasta = $bruto -replace '%USERPROFILE%', $PerfilUsuario }
        }
        $pastas = @(@{ Origem = 'Usuario\PastaInicializar'; Pasta = $pasta; Aprov = "$aprov\StartupFolder" })
    }
    foreach ($r in $runs) {
        $k = Get-Item -LiteralPath "$Raiz\$($r.Run)" -ErrorAction SilentlyContinue
        if (-not $k) { continue }
        foreach ($nome in $k.GetValueNames()) {
            if (-not $nome) { continue }
            [pscustomobject]@{ Origem = $r.Origem; Nome = $nome; Comando = [string]$k.GetValue($nome); Raiz = $Raiz; SubAprov = $r.Aprov; Escopo = $Escopo }
        }
    }
    foreach ($p in $pastas) {
        if (-not $p.Pasta -or -not (Test-Path -LiteralPath $p.Pasta)) { continue }
        foreach ($a in Get-ChildItem -LiteralPath $p.Pasta -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' }) {
            [pscustomobject]@{ Origem = $p.Origem; Nome = $a.Name; Comando = $a.FullName; Raiz = $Raiz; SubAprov = $p.Aprov; Escopo = $Escopo }
        }
    }
}

function Disable-EntradaInicializacao {
    <# Desabilita uma entrada como o Gerenciador de Tarefas: 03 00 00 00 + FILETIME em StartupApproved. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Simulação via Sessao.Simular.')]
    param([Parameter(Mandatory)]$Sessao, [Parameter(Mandatory)]$Entrada, [Parameter(Mandatory)]$Perfil, [string]$Sid)
    $alvo = "$($Entrada.Origem)\$($Entrada.Nome)"
    if (Test-ComponenteWindows $Entrada.Comando) {
        return Write-LogOtimizacao -Sessao $Sessao -Item 'I1' -Alvo $alvo -Resultado Pulado -Detalhe 'Componente do Windows (executável em %windir%): intocável.'
    }
    if (Test-Protegido -Perfil $Perfil -Categoria 'Inicializacao' -Nome $Entrada.Nome) {
        return Write-LogOtimizacao -Sessao $Sessao -Item 'I1' -Alvo $alvo -Resultado Pulado -Detalhe 'Protegido no perfil.'
    }
    $atual = Get-ValorRegistro -Caminho "$($Entrada.Raiz)\$($Entrada.SubAprov)" -Nome $Entrada.Nome
    if ($atual.Existe -and $atual.Valor -is [byte[]] -and $atual.Valor.Length -and ($atual.Valor[0] -band 1)) {
        return Write-LogOtimizacao -Sessao $Sessao -Item 'I1' -Alvo $alvo -ValorAnterior 'desabilitada' -Resultado JaAplicado
    }
    $novo = [byte[]](@(3, 0, 0, 0) + [BitConverter]::GetBytes([DateTime]::UtcNow.ToFileTimeUtc()))
    Set-ValorRegistro -Sessao $Sessao -Item 'I1' -Raiz $Entrada.Raiz -SubChave $Entrada.SubAprov -Nome $Entrada.Nome -Valor $novo -Tipo Binary -Escopo $Entrada.Escopo -Sid $Sid
}

function Invoke-I1 {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Parâmetros usados no scriptblock executado no hive do usuário.')]
    param($Sessao, $Perfil, $Alvo)
    $nomes = @(Get-Opcao $Perfil 'I1Desabilitar' | Where-Object { $_ })
    if (-not $nomes.Count) {
        return Write-LogOtimizacao -Sessao $Sessao -Item 'I1' -Alvo 'Opcoes.I1Desabilitar' -Resultado Pulado -Detalhe 'Lista vazia: nenhuma entrada a desabilitar.' | Out-Null
    }
    $achados = New-Object System.Collections.Generic.List[string]
    foreach ($e in @(Get-FonteInicializacao -Raiz $script:HKLM -Escopo Maquina)) {
        if ($nomes -notcontains $e.Nome) { continue }
        $achados.Add($e.Nome)
        Disable-EntradaInicializacao -Sessao $Sessao -Entrada $e -Perfil $Perfil | Out-Null
    }
    Invoke-NoHiveUsuario -Sid $Alvo.Sid -Perfil $Alvo.Perfil -ScriptBlock {
        param($raiz)
        foreach ($e in @(Get-FonteInicializacao -Raiz $raiz -Escopo Usuario -PerfilUsuario $Alvo.Perfil)) {
            if ($nomes -notcontains $e.Nome) { continue }
            $achados.Add($e.Nome)
            Disable-EntradaInicializacao -Sessao $Sessao -Entrada $e -Perfil $Perfil -Sid $Alvo.Sid | Out-Null
        }
    }
    foreach ($n in $nomes | Where-Object { $achados -notcontains $_ }) {
        Write-LogOtimizacao -Sessao $Sessao -Item 'I1' -Alvo $n -Resultado Pulado -Detalhe 'Entrada não encontrada na máquina nem no usuário alvo.' | Out-Null
    }
}

#endregion

#region I2 a I8, I11 e I12: políticas

function Set-Politica {
    <# Política de máquina (HKLM), pulando valor já definido com outro conteúdo (GPO). #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Simulação via Sessao.Simular, tratada em Set-ValorRegistro.')]
    param($Sessao, [string]$Item, [string]$SubChave, [string]$Nome, $Valor, [string]$Tipo = 'DWord')
    Set-ValorRegistro -Sessao $Sessao -Item $Item -Raiz $script:HKLM -SubChave $SubChave -Nome $Nome -Valor $Valor -Tipo $Tipo -PularSeDefinido | Out-Null
}

function Invoke-I2 {
    param($Sessao)
    if (-not (Test-AppInstalado 'msedge.exe')) {
        return Write-LogOtimizacao -Sessao $Sessao -Item 'I2' -Alvo 'Microsoft Edge' -Resultado Pulado -Detalhe 'Edge não instalado.' | Out-Null
    }
    Set-Politica -Sessao $Sessao -Item 'I2' -SubChave 'SOFTWARE\Policies\Microsoft\Edge' -Nome 'StartupBoostEnabled' -Valor 0
    Set-Politica -Sessao $Sessao -Item 'I2' -SubChave 'SOFTWARE\Policies\Microsoft\Edge' -Nome 'BackgroundModeEnabled' -Valor 0
}

function Invoke-I3 {
    param($Sessao)
    if (-not (Test-AppInstalado 'chrome.exe')) {
        return Write-LogOtimizacao -Sessao $Sessao -Item 'I3' -Alvo 'Google Chrome' -Resultado Pulado -Detalhe 'Chrome não instalado.' | Out-Null
    }
    Set-Politica -Sessao $Sessao -Item 'I3' -SubChave 'SOFTWARE\Policies\Google\Chrome' -Nome 'BackgroundModeEnabled' -Valor 0
}

function Invoke-I4 {
    param($Sessao, $Perfil)
    $apps = @(Get-Opcao $Perfil 'I4NegarSegundoPlano' | Where-Object { $_ } | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    if (-not $apps.Count) {
        return Write-LogOtimizacao -Sessao $Sessao -Item 'I4' -Alvo 'Opcoes.I4NegarSegundoPlano' -Resultado Pulado -Detalhe 'Lista vazia: nenhum app a negar (nunca se nega para todos).' | Out-Null
    }
    $invalidos = @($apps | Where-Object { $_ -notmatch '^[A-Za-z0-9.\-]+_[a-z0-9]{13}$' })
    if ($invalidos.Count) { throw "Package Family Name inválido em Opcoes.I4NegarSegundoPlano: $($invalidos -join ', ')." }
    $sub = 'SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'
    # Mesmo par de valores que a GPO grava: padrão "usuário decide" (0) e a lista de negação (multiText).
    Set-Politica -Sessao $Sessao -Item 'I4' -SubChave $sub -Nome 'LetAppsRunInBackground' -Valor 0
    Set-Politica -Sessao $Sessao -Item 'I4' -SubChave $sub -Nome 'LetAppsRunInBackground_ForceDenyTheseApps' -Valor ([string[]]$apps) -Tipo MultiString
}

function Invoke-I5 {
    param($Sessao, $Info)
    if ($Info.Build -lt 22000) {
        return Write-LogOtimizacao -Sessao $Sessao -Item 'I5' -Alvo 'Widgets' -Resultado Pulado -Detalhe "Política de widgets é do Windows 11 (build atual $($Info.Build))." | Out-Null
    }
    # Com o UCPD ativo, gravar e apagar esta política pelo PowerShell ou reg.exe dá acesso negado (medido na 26300.9457):
    # a chave Dsh criada ficaria sem poder ser removida na reversão. Por isso decide antes de gravar.
    if (Test-UcpdAtivo) {
        return Write-LogOtimizacao -Sessao $Sessao -Item 'I5' -Alvo 'Widgets' -Resultado Pulado -Detalhe $script:MotivoI5Ucpd | Out-Null
    }
    Set-Politica -Sessao $Sessao -Item 'I5' -SubChave 'SOFTWARE\Policies\Microsoft\Dsh' -Nome 'AllowNewsAndInterests' -Valor 0
}

function Test-UcpdAtivo {
    <# Driver UCPD (User Choice Protection Driver) em execução. #>
    'Running' -eq (Get-CimInstance -ClassName Win32_SystemDriver -Filter "Name='UCPD'" -ErrorAction SilentlyContinue).State
}

function Invoke-I6 {
    param($Sessao)
    $instalados = @(Get-AppxPackage -AllUsers -Name $script:PacoteCopilot -ErrorAction Stop)
    $provisionados = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop | Where-Object { $_.DisplayName -eq $script:PacoteCopilot })
    if (-not $instalados.Count -and -not $provisionados.Count) {
        return Write-LogOtimizacao -Sessao $Sessao -Item 'I6' -Alvo $script:PacoteCopilot -Resultado JaAplicado -Detalhe 'Não instalado.' | Out-Null
    }
    $antes = (@($instalados | ForEach-Object { $_.PackageFullName }) + @($provisionados | ForEach-Object { "provisionado: $($_.PackageName)" })) -join '; '
    if ($Sessao.Simular) {
        return Write-LogOtimizacao -Sessao $Sessao -Item 'I6' -Alvo $script:PacoteCopilot -ValorAnterior $antes -ValorNovo 'removido' -Resultado Simulado | Out-Null
    }
    Add-EstadoOriginal -Sessao $Sessao -Entrada @{ Tipo = 'AppRemovido'; Item = 'I6'; Nome = $script:PacoteCopilot; Pacotes = $antes }
    # Provisionamento primeiro: medido na VM 26300 (Aplicativos), Remove-AppxProvisionedPackage logo após Remove-AppxPackage -AllUsers
    # falhou com 0x80070002; na ordem inversa as duas remoções concluem.
    foreach ($p in $provisionados) { Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -ErrorAction Stop | Out-Null }
    foreach ($p in $instalados) { Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop }
    $resta = @(Get-AppxPackage -AllUsers -Name $script:PacoteCopilot).Count + @(Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -eq $script:PacoteCopilot }).Count
    if ($resta) { throw "O pacote $($script:PacoteCopilot) continua presente após a remoção." }
    Write-LogOtimizacao -Sessao $Sessao -Item 'I6' -Alvo $script:PacoteCopilot -ValorAnterior $antes -ValorNovo 'removido' -Resultado OK -Detalhe 'Reversão: reinstalar pela Microsoft Store.' | Out-Null
}

function Invoke-I8 {
    param($Sessao)
    Set-Politica -Sessao $Sessao -Item 'I8' -SubChave 'SOFTWARE\Policies\Microsoft\Windows\GameDVR' -Nome 'AllowGameDVR' -Valor 0
}

function Invoke-I11Maquina {
    param($Sessao, $Info)
    if ($Info.EditionId -notmatch '^(Enterprise|Education)') {
        return Write-LogOtimizacao -Sessao $Sessao -Item 'I11' -Alvo 'DisableWindowsConsumerFeatures, DisableSoftLanding' -Resultado Info `
            -Detalhe "Edição $($Info.EditionId): essas políticas valem só em Enterprise e Education (Experience CSP). Aplicada apenas a de sugestões de terceiros." | Out-Null
    }
    Set-Politica -Sessao $Sessao -Item 'I11' -SubChave 'SOFTWARE\Policies\Microsoft\Windows\CloudContent' -Nome 'DisableWindowsConsumerFeatures' -Valor 1
    Set-Politica -Sessao $Sessao -Item 'I11' -SubChave 'SOFTWARE\Policies\Microsoft\Windows\CloudContent' -Nome 'DisableSoftLanding' -Valor 1
}

function Get-EstadoRecall {
    <# Estado do componente opcional Recall, ou $null se não existir. #>
    $f = Get-WindowsOptionalFeature -Online -FeatureName Recall -ErrorAction SilentlyContinue
    if ($f) { [string]$f.State } else { $null }
}

function Invoke-I12 {
    param($Sessao, $Info)
    $estado = Get-EstadoRecall
    if (-not $estado -or $estado -eq 'DisabledWithPayloadRemoved') {
        return Write-LogOtimizacao -Sessao $Sessao -Item 'I12' -Alvo 'Recall' -ValorAnterior $estado -Resultado Pulado -Detalhe 'Sem componente Recall com conteúdo: não é PC Copilot+.' | Out-Null
    }
    $sub = 'SOFTWARE\Policies\Microsoft\Windows\WindowsAI'
    Set-Politica -Sessao $Sessao -Item 'I12' -SubChave $sub -Nome 'DisableAIDataAnalysis' -Valor 1
    Set-Politica -Sessao $Sessao -Item 'I12' -SubChave $sub -Nome 'DisableClickToDo' -Valor 1
    if ($Info.Build -eq 26100 -and $Info.UBR -lt 3915) {
        Write-LogOtimizacao -Sessao $Sessao -Item 'I12' -Alvo 'DisableAIDataAnalysis' -Resultado Info -Detalhe "Documentada a partir de 26100.3915 (atual $($Info.Build).$($Info.UBR))." | Out-Null
    }
}

#endregion

#region I9 e I10: tarefas e serviços

function Invoke-I9 {
    param($Sessao, $Perfil)
    $lista = @(Get-Opcao $Perfil 'I9Tarefas' | Where-Object { $_ })
    if (-not $lista.Count) {
        return Write-LogOtimizacao -Sessao $Sessao -Item 'I9' -Alvo 'Opcoes.I9Tarefas' -Resultado Pulado -Detalhe 'Lista vazia: nenhuma tarefa a desabilitar.' | Out-Null
    }
    foreach ($completo in $lista) {
        Invoke-ItemOtimizacao -Sessao $Sessao -Id 'I9' -Acao {
            $i = $completo.LastIndexOf('\')
            if (-not $completo.StartsWith('\') -or $i -lt 0) { throw "Tarefa '$completo' fora do formato '\Pasta\Nome'." }
            $caminho = $completo.Substring(0, $i + 1); $nome = $completo.Substring($i + 1)
            if ($caminho -like '\Microsoft\*') {
                return Write-LogOtimizacao -Sessao $Sessao -Item 'I9' -Alvo $completo -Resultado Pulado -Detalhe 'Tarefa do Windows (\Microsoft\): intocável.' | Out-Null
            }
            if ((Test-Protegido -Perfil $Perfil -Categoria 'Tarefas' -Nome $completo) -or (Test-Protegido -Perfil $Perfil -Categoria 'Tarefas' -Nome $nome)) {
                return Write-LogOtimizacao -Sessao $Sessao -Item 'I9' -Alvo $completo -Resultado Pulado -Detalhe 'Protegida no perfil.' | Out-Null
            }
            $t = Get-ScheduledTask -TaskPath $caminho -TaskName $nome -ErrorAction SilentlyContinue
            if (-not $t) {
                return Write-LogOtimizacao -Sessao $Sessao -Item 'I9' -Alvo $completo -Resultado Pulado -Detalhe 'Tarefa não encontrada.' | Out-Null
            }
            $estado = [string]$t.State
            if ($estado -eq 'Disabled') {
                return Write-LogOtimizacao -Sessao $Sessao -Item 'I9' -Alvo $completo -ValorAnterior $estado -Resultado JaAplicado | Out-Null
            }
            if ($Sessao.Simular) {
                return Write-LogOtimizacao -Sessao $Sessao -Item 'I9' -Alvo $completo -ValorAnterior $estado -ValorNovo 'Disabled' -Resultado Simulado | Out-Null
            }
            Add-EstadoOriginal -Sessao $Sessao -Entrada @{ Tipo = 'Tarefa'; Item = 'I9'; Caminho = $caminho; Nome = $nome; Estado = $estado }
            Disable-ScheduledTask -TaskPath $caminho -TaskName $nome -ErrorAction Stop | Out-Null
            $novo = [string](Get-ScheduledTask -TaskPath $caminho -TaskName $nome).State
            if ($novo -ne 'Disabled') { throw "A tarefa $completo continua $novo." }
            Write-LogOtimizacao -Sessao $Sessao -Item 'I9' -Alvo $completo -ValorAnterior $estado -ValorNovo $novo -Resultado OK | Out-Null
        }
    }
}

function Get-InicioServico {
    <# Tipo de início pelo registro do serviço: Start 2 automático (DelayedAutostart 1 = atrasado), 3 manual, 4 desativado. #>
    param([string]$Nome)
    $k = Get-Item -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$Nome" -ErrorAction SilentlyContinue
    if (-not $k) { return $null }
    $atrasado = $k.GetValue('DelayedAutostart')
    [pscustomobject]@{ Start = [int]$k.GetValue('Start'); Atrasado = [bool]($atrasado -eq 1); Tipo = [int]$k.GetValue('Type'); ImagePath = [string]$k.GetValue('ImagePath', $null, 'DoNotExpandEnvironmentNames') }
}

function Set-InicioServico {
    <# Define o tipo de início (Set-Service) e o início atrasado (valor DelayedAutostart, que Set-Service não cobre no 5.1). #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Chamada apenas fora da simulação.')]
    param([string]$Nome, [int]$Start, [bool]$Atrasado)
    $tipo = switch ($Start) { 2 { 'Automatic' } 3 { 'Manual' } 4 { 'Disabled' } default { throw "Tipo de início $Start não tratado." } }
    Set-Service -Name $Nome -StartupType $tipo -ErrorAction Stop
    $chave = "HKLM:\SYSTEM\CurrentControlSet\Services\$Nome"
    if ($Start -eq 2 -and $Atrasado) { New-ItemProperty -LiteralPath $chave -Name 'DelayedAutostart' -Value 1 -PropertyType DWord -Force | Out-Null }
    elseif ((Get-Item -LiteralPath $chave).GetValue('DelayedAutostart') -eq 1) { New-ItemProperty -LiteralPath $chave -Name 'DelayedAutostart' -Value 0 -PropertyType DWord -Force | Out-Null }
    $lido = Get-InicioServico $Nome
    if ($lido.Start -ne $Start -or ($Start -eq 2 -and $lido.Atrasado -ne $Atrasado)) { throw "Tipo de início do serviço $Nome divergente após a alteração." }
}

function Invoke-I10 {
    param($Sessao, $Perfil)
    $mapa = Get-Opcao $Perfil 'I10Servicos'
    if (-not $mapa -or -not $mapa.Count) {
        return Write-LogOtimizacao -Sessao $Sessao -Item 'I10' -Alvo 'Opcoes.I10Servicos' -Resultado Pulado -Detalhe 'Lista vazia: nenhum serviço a alterar.' | Out-Null
    }
    $codigos = @{ Manual = 3; Disabled = 4 }
    foreach ($nome in @($mapa.Keys)) {
        Invoke-ItemOtimizacao -Sessao $Sessao -Id 'I10' -Acao {
            $destino = [string]$mapa[$nome]
            if (-not $codigos.ContainsKey($destino)) { throw "Serviço ${nome}: destino '$destino' inválido (use Manual ou Disabled)." }
            if (Test-Protegido -Perfil $Perfil -Categoria 'Servicos' -Nome $nome) {
                return Write-LogOtimizacao -Sessao $Sessao -Item 'I10' -Alvo $nome -Resultado Pulado -Detalhe 'Protegido no perfil.' | Out-Null
            }
            $atual = Get-InicioServico $nome
            if (-not $atual) {
                return Write-LogOtimizacao -Sessao $Sessao -Item 'I10' -Alvo $nome -Resultado Pulado -Detalhe 'Serviço não encontrado.' | Out-Null
            }
            # Type 0x10/0x20 = serviço Win32 (próprio ou compartilhado); 0x1/0x2 = driver. Start 0/1 = boot/sistema.
            if (-not ($atual.Tipo -band 0x30) -or $atual.Start -lt 2) {
                return Write-LogOtimizacao -Sessao $Sessao -Item 'I10' -Alvo $nome -Resultado Pulado -Detalhe 'Driver ou serviço de boot/sistema: intocável.' | Out-Null
            }
            if (Test-ComponenteWindows $atual.ImagePath) {
                return Write-LogOtimizacao -Sessao $Sessao -Item 'I10' -Alvo $nome -Resultado Pulado -Detalhe 'Serviço do Windows (executável em %windir%): intocável.' | Out-Null
            }
            $alvoStart = $codigos[$destino]
            $antes = '{0}{1}' -f $atual.Start, $(if ($atual.Atrasado) { ' (atrasado)' } else { '' })
            if ($atual.Start -eq $alvoStart) {
                return Write-LogOtimizacao -Sessao $Sessao -Item 'I10' -Alvo $nome -ValorAnterior $antes -ValorNovo $alvoStart -Resultado JaAplicado | Out-Null
            }
            if ($Sessao.Simular) {
                return Write-LogOtimizacao -Sessao $Sessao -Item 'I10' -Alvo $nome -ValorAnterior $antes -ValorNovo "$alvoStart ($destino)" -Resultado Simulado | Out-Null
            }
            Add-EstadoOriginal -Sessao $Sessao -Entrada @{ Tipo = 'Servico'; Item = 'I10'; Nome = $nome; Start = $atual.Start; Atrasado = $atual.Atrasado }
            Set-InicioServico -Nome $nome -Start $alvoStart -Atrasado $false
            Write-LogOtimizacao -Sessao $Sessao -Item 'I10' -Alvo $nome -ValorAnterior $antes -ValorNovo "$alvoStart ($destino)" -Resultado OK -Detalhe 'Vale a partir da próxima inicialização; o serviço não foi parado.' | Out-Null
        }
    }
}

#endregion

#region Itens do usuário (HKCU do usuário alvo)

function Invoke-ItemUsuario {
    <# I7 e I11 (parte do usuário) no hive do usuário alvo. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Parâmetros usados no scriptblock executado no hive do usuário.')]
    param($Sessao, $Alvo, [string[]]$Itens)
    Invoke-NoHiveUsuario -Sid $Alvo.Sid -Perfil $Alvo.Perfil -ScriptBlock {
        param($raiz)
        $comum = @{ Sessao = $Sessao; Raiz = $raiz; Escopo = 'Usuario'; Sid = $Alvo.Sid; PularSeDefinido = $true }
        if ($Itens -contains 'I7') {
            Invoke-ItemOtimizacao -Sessao $Sessao -Id 'I7' -Acao {
                Set-ValorRegistro @comum -Item 'I7' -SubChave 'Software\Policies\Microsoft\Windows\Explorer' -Nome 'DisableSearchBoxSuggestions' -Valor 1 | Out-Null
                Write-LogOtimizacao -Sessao $Sessao -Item 'I7' -Alvo 'Busca do Iniciar' -Resultado Info -Detalhe 'Confiança baixa: efeito no Iniciar não documentado pela Microsoft. Conferir no cliente após sair e entrar.' | Out-Null
            }
        }
        if ($Itens -contains 'I11') {
            Invoke-ItemOtimizacao -Sessao $Sessao -Id 'I11' -Acao {
                Set-ValorRegistro @comum -Item 'I11' -SubChave 'Software\Policies\Microsoft\Windows\CloudContent' -Nome 'DisableThirdPartySuggestions' -Valor 1 | Out-Null
            }
        }
    }
}

#endregion

#region Reversão de entradas que não são registro

function Get-ManipuladorReversao {
    <# Manipuladores de reversão. Invoke-Reversao passa a entrada e a sessão como argumentos. #>
    @{
        Tarefa      = {
            param($e, $Sessao)
            $alvo = "$($e.Caminho)$($e.Nome)"
            if ($Sessao.Simular) { return Write-LogOtimizacao -Sessao $Sessao -Item $e.Item -Alvo $alvo -ValorNovo $e.Estado -Resultado Simulado }
            if ($e.Estado -eq 'Disabled') { Disable-ScheduledTask -TaskPath $e.Caminho -TaskName $e.Nome -ErrorAction Stop | Out-Null }
            else { Enable-ScheduledTask -TaskPath $e.Caminho -TaskName $e.Nome -ErrorAction Stop | Out-Null }
            $atual = [string](Get-ScheduledTask -TaskPath $e.Caminho -TaskName $e.Nome).State
            if (($e.Estado -eq 'Disabled') -ne ($atual -eq 'Disabled')) { throw "Reversão divergente na tarefa $alvo." }
            Write-LogOtimizacao -Sessao $Sessao -Item $e.Item -Alvo $alvo -ValorNovo $atual -Resultado Revertido
        }
        Servico     = {
            param($e, $Sessao)
            if ($Sessao.Simular) { return Write-LogOtimizacao -Sessao $Sessao -Item $e.Item -Alvo $e.Nome -ValorNovo $e.Start -Resultado Simulado }
            Set-InicioServico -Nome $e.Nome -Start ([int]$e.Start) -Atrasado ([bool]$e.Atrasado)
            Write-LogOtimizacao -Sessao $Sessao -Item $e.Item -Alvo $e.Nome -ValorNovo ('{0}{1}' -f $e.Start, $(if ($e.Atrasado) { ' (atrasado)' } else { '' })) -Resultado Revertido
        }
        AppRemovido = {
            param($e, $Sessao)
            Write-LogOtimizacao -Sessao $Sessao -Item $e.Item -Alvo $e.Nome -ValorAnterior $e.Pacotes -Resultado Pulado -Detalhe 'Sem reversão automática: reinstalar pela Microsoft Store.'
        }
    }
}

#endregion

#region Execução

function Invoke-Inicializacao {
    param([string]$Perfil, [switch]$Revert, [string]$Sessao, [switch]$PermitirReinicializacaoPendente, [switch]$Simular)

    $p = Import-PerfilCliente -Caminho $Perfil
    $pre = Test-PreCondicao -PermitirReinicializacaoPendente:$PermitirReinicializacaoPendente
    foreach ($a in $pre.Avisos) { Write-Warning $a }
    if ($pre.Bloqueios.Count) {
        foreach ($b in $pre.Bloqueios) { Write-Warning "BLOQUEIO: $b" }
        if (-not $Simular) { throw 'Execução bloqueada pelas pré-checagens. Nada foi alterado.' }
    }

    # A sessão da reversão tem nome próprio para não ser confundida com uma sessão de aplicação pendente.
    $nomeSessao = if ($Revert) { "$($script:NomeScript)-Reversao" } else { $script:NomeScript }
    $s = New-SessaoOtimizacao -Cliente $p.Cliente -Script $nomeSessao -Simular:$Simular

    if ($Revert) {
        Invoke-ReversaoPendente -Sessao $s -Cliente $p.Cliente -Script $script:NomeScript -Pasta $Sessao -Manipuladores (Get-ManipuladorReversao)
        return $s
    }

    $itens = Get-ItemPerfil -Perfil $p -Prefixo 'I'
    if (-not $itens.Count) { Write-Warning 'Nenhum item I* no perfil. Nada a fazer.'; return }
    $info = Get-InfoWindows
    $doUsuario = @($itens | Where-Object { $_ -in 'I1', 'I7', 'I11' })
    $alvoUsuario = $null
    if ($doUsuario.Count) {
        $alvoUsuario = Get-UsuarioAlvo -Sid $p.UsuarioSid
        Write-LogOtimizacao -Sessao $s -Item 'Contexto' -Alvo 'Usuário alvo' -ValorNovo $alvoUsuario.Sid -Resultado Info -Detalhe "Executado por $env:USERDOMAIN\$env:USERNAME" | Out-Null
    }

    if (-not $Simular) {
        try {
            $rp = New-PontoRestauracao -Descricao "Otimizacao $($script:NomeScript) $($p.Cliente)"
            Write-LogOtimizacao -Sessao $s -Item 'Backup' -Alvo 'Ponto de restauração' -ValorNovo $rp.SequenceNumber -Resultado OK | Out-Null
        }
        catch {
            Write-LogOtimizacao -Sessao $s -Item 'Backup' -Alvo 'Ponto de restauração' -Resultado Falha -Detalhe $_.Exception.Message | Out-Null
            throw "Backup falhou: nada foi alterado. $($_.Exception.Message)"
        }
    }

    $acoes = [ordered]@{
        I1  = { Invoke-I1 -Sessao $s -Perfil $p -Alvo $alvoUsuario }
        I2  = { Invoke-I2 -Sessao $s }
        I3  = { Invoke-I3 -Sessao $s }
        I4  = { Invoke-I4 -Sessao $s -Perfil $p }
        I5  = { Invoke-I5 -Sessao $s -Info $info }
        I6  = { Invoke-I6 -Sessao $s }
        I8  = { Invoke-I8 -Sessao $s }
        I9  = { Invoke-I9 -Sessao $s -Perfil $p }
        I10 = { Invoke-I10 -Sessao $s -Perfil $p }
        I11 = { Invoke-I11Maquina -Sessao $s -Info $info }
        I12 = { Invoke-I12 -Sessao $s -Info $info }
    }
    foreach ($id in $acoes.Keys) {
        if ($itens -contains $id) { Invoke-ItemOtimizacao -Sessao $s -Id $id -Acao $acoes[$id] }
    }
    $itensUsuario = @($itens | Where-Object { $_ -in 'I7', 'I11' })
    if ($itensUsuario.Count) {
        Invoke-ItemOtimizacao -Sessao $s -Id 'Usuario' -Acao { Invoke-ItemUsuario -Sessao $s -Alvo $alvoUsuario -Itens $itensUsuario }
    }
    $s
}

# Permite carregar as funções com dot-source (testes) sem executar.
if ($MyInvocation.InvocationName -ne '.') {
    $s = Invoke-Inicializacao -Perfil $Perfil -Revert:$Revert -Sessao $Sessao -PermitirReinicializacaoPendente:$PermitirReinicializacaoPendente -Simular:([bool]$WhatIfPreference)
    if ($s) {
        $s.Linhas | Format-Table -Property Item, Alvo, ValorAnterior, ValorNovo, Resultado, Detalhe -AutoSize -Wrap | Out-String -Width 220
        Get-ResumoSessao -Sessao $s | Format-Table -AutoSize | Out-String
        if ($s.Pasta) { "Sessão: $($s.Pasta)" }
        if (@($s.Linhas | Where-Object Resultado -eq 'Falha').Count) { exit 1 }
    }
}

#endregion
