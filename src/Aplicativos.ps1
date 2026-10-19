<#
.SYNOPSIS
    Remoção de aplicativos (itens A1 a A4 do catálogo) conforme o perfil do cliente: apps de consumo do Windows,
    programas do fabricante aprovados por cliente e Teams pessoal.

.DESCRIPTION
    Aplica somente os itens A* listados em Aplicar no perfil e não listados em Pular. Ordem: A4, A1, A2.

      A1  Apps de consumo da lista base (Clipchamp, Notícias, Clima, Solitaire, Xbox exceto Identity e TCUI,
          Introdução, Hub de Comentários, Mapas, Filmes, Family, Mixed Reality, 3D, Paint 3D e jogos e streaming de
          fábrica). Aprovar A1 aprova a lista inteira; exceções em Protegidos.Aplicativos (nome do pacote ou nome de
          exibição, aceita curinga). Remove para todos os usuários (Remove-AppxPackage -AllUsers) e o provisionamento
          (Remove-AppxProvisionedPackage -Online), para não voltar em contas novas.
      A2  Programas do fabricante listados em Opcoes.A2Remover (Nome ou Id como aparecem na seção Programas da Coleta,
          aceita curinga). Appx: como no A1. MSI da máquina: msiexec /x {ProductCode} /qn /norestart (3010 = reiniciar,
          1605 = já removido). Instalador EXE: não remove, registra o desinstalador para remoção manual. Programas
          instalados só no perfil de um usuário (HKCU) não são vistos pelo A2: remoção manual.
      A3  OneDrive não é removido (decisão do projeto). Para tirá-lo da inicialização, usar o I1 (Inicializacao).
      A4  Teams pessoal do Windows 11 (pacote MicrosoftTeams, o "Chat"). O Teams novo (MSTeams) nunca é tocado.

    Nunca remove: Assistência Rápida, Notas Autoadesivas, To Do, Teams novo, Power Automate, Microsoft Store e seus
    componentes, Instalador de Aplicativo, Edge, Segurança do Windows, Xbox Identity e TCUI, frameworks, pacotes
    NonRemovable ou do sistema (SignatureKind System), programas da Microsoft no A2, ferramentas de driver e BIOS
    (Dell Command Update, Dell SupportAssist, HP Support Assistant, Lenovo Vantage, Lenovo System Update) e nomes em
    Protegidos.Aplicativos. Sem Microsoft Store instalada, não remove Appx (não haveria como reinstalar).

    Ponto de restauração antes de remover. O estado original (pacotes, versão, ProductCode) fica em
    %ProgramData%\Otimizacao\<Cliente>\<data>-Aplicativos\estado-original.json.

.PARAMETER Perfil
    Arquivo .psd1 do cliente.

.PARAMETER Revert
    Lista o que cada sessão removeu e verifica o que já voltou. Não reinstala: não há reinstalação offline de Appx
    nem de MSI. Para cada item ausente, indica o nome a buscar na Microsoft Store e o link
    ms-windows-store://pdp/?PFN=<PackageFamilyName> (Appx) ou o instalador do fabricante (MSI). Depois de reinstalar,
    executar de novo com -Revert -Sessao <pasta da aplicação> para conferir.

.PARAMETER Sessao
    Pasta da sessão a reverter ou conferir.

.PARAMETER PermitirReinicializacaoPendente
    Não bloqueia a execução quando há reinicialização pendente.

.EXAMPLE
    .\Aplicativos.ps1 -Perfil .\perfis\ClienteX.psd1 -WhatIf

.EXAMPLE
    .\Aplicativos.ps1 -Perfil .\perfis\ClienteX.psd1 -Revert

.NOTES
    O que se perde: os apps removidos e, no A1, a gravação de tela Win+G (Game Bar) e o app Xbox. A reinstalação é
    manual, pela Microsoft Store (Appx) ou pelo instalador do fabricante (MSI). O ponto de restauração não devolve
    apps removidos de forma confiável.
    Reversão: manual, conferida por -Revert.
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

$script:NomeScript = 'Aplicativos'

# A1. Nomes lidos na VM 26300 (confiança alta) e, para builds antigas, nomes de referência do Win11Debloat (média).
$script:ListaA1 = @(
    'Clipchamp.Clipchamp', 'Microsoft.BingNews', 'Microsoft.BingWeather', 'Microsoft.MicrosoftSolitaireCollection'
    'Microsoft.GamingApp', 'Microsoft.XboxGamingOverlay', 'Microsoft.XboxSpeechToTextOverlay', 'Microsoft.WindowsFeedbackHub'
    'Microsoft.GetStarted', 'Microsoft.WindowsMaps', 'Microsoft.ZuneVideo', 'MicrosoftCorporationII.MicrosoftFamily'
    'Microsoft.MixedReality.Portal', 'Microsoft.Microsoft3DViewer', 'Microsoft.Print3D', 'Microsoft.MSPaint'
    'king.com.CandyCrushSaga', 'SpotifyAB.SpotifyMusic', 'Disney.37853FC22B2CE', 'BytedancePte.Ltd.TikTok', 'AmazonVideo.PrimeVideo'
)
# A4. Teams pessoal (Microsoft Q&A a/1434245). MSTeams é o Teams novo e está em NuncaRemover.
$script:PacoteA4 = 'MicrosoftTeams'

$script:NuncaRemover = @(
    'MicrosoftCorporationII.QuickAssist', 'Microsoft.MicrosoftStickyNotes', 'Microsoft.Todos', 'MSTeams', 'Microsoft.PowerAutomateDesktop'
    'Microsoft.WindowsStore', 'Microsoft.StorePurchaseApp', 'Microsoft.DesktopAppInstaller', 'Microsoft.MicrosoftEdge.Stable'
    'Microsoft.SecHealthUI', 'Microsoft.Xbox.TCUI', 'Microsoft.XboxIdentityProvider'
)
# Ferramentas de driver e BIOS do fabricante (nome de exibição ou do pacote).
$script:FerramentasFabricante = @(
    '*Command*Update*', '*SupportAssist*', '*Support Assistant*', '*Vantage*', 'Lenovo System Update'
    'AD2F1837.HPSupportAssistant', 'E046963F.LenovoCompanion'
)

#region Auxiliares

function Get-Opcao {
    param($Perfil, [string]$Nome)
    if ($Perfil.Opcoes -and $Perfil.Opcoes.ContainsKey($Nome)) { $Perfil.Opcoes[$Nome] } else { $null }
}

function Write-Achado {
    <# Resultado que pede ação do técnico: linha Info com ATENÇÃO e aviso na tela. #>
    param($Sessao, [string]$Item, [string]$Alvo, $ValorAnterior, [string]$Detalhe)
    Write-Warning "[$Item] $Alvo : $Detalhe"
    Write-LogOtimizacao -Sessao $Sessao -Item $Item -Alvo $Alvo -ValorAnterior $ValorAnterior -Resultado Info -Detalhe "ATENÇÃO: $Detalhe" | Out-Null
}

function Get-MotivoProibido {
    <# Motivo pelo qual o programa nunca é removido, ou $null. Programa: Nome, Id, Fabricante. #>
    param([Parameter(Mandatory)]$Programa, $Perfil, [switch]$A2)
    $nomes = @($Programa.Nome, $Programa.Id) | Where-Object { $_ }
    foreach ($n in $nomes) {
        if ($script:NuncaRemover -contains $n) { return 'Na lista de apps que nunca são removidos.' }
        foreach ($p in $script:FerramentasFabricante) { if ($n -like $p) { return 'Ferramenta de driver e BIOS do fabricante.' } }
        if ($Perfil -and (Test-Protegido -Perfil $Perfil -Categoria 'Aplicativos' -Nome $n)) { return 'Protegido no perfil.' }
    }
    if ($A2 -and [string]$Programa.Fabricante -like 'Microsoft*') { return 'Programa da Microsoft: fora do A2 (apps de consumo são do A1 e do A4).' }
    $null
}

function Get-TamanhoMB {
    param([string]$Pasta)
    if (-not $Pasta -or -not (Test-Path -LiteralPath $Pasta)) { return $null }
    [math]::Round((Get-ChildItem -LiteralPath $Pasta -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1MB, 1)
}

function Test-LojaDisponivel {
    [bool]@(Get-AppxPackage -AllUsers -Name 'Microsoft.WindowsStore' -ErrorAction Stop).Count
}

#endregion

#region Appx (A1, A2, A4)

function Get-PacoteAppx {
    <# Instalações (todos os usuários) e provisionamento de um pacote pelo nome. #>
    param([Parameter(Mandatory)][string]$Nome)
    [pscustomobject]@{
        Instalados    = @(Get-AppxPackage -AllUsers -Name $Nome -ErrorAction Stop)
        Provisionados = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop | Where-Object { $_.DisplayName -eq $Nome })
    }
}

function Remove-PacoteAppx {
    <# Remove um pacote para todos os usuários e o provisionamento, com backup, simulação e leitura de volta. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Simulação via Sessao.Simular, derivado de -WhatIf.')]
    param($Sessao, [string]$Item, [string]$Nome, $Perfil, [bool]$Loja)
    $p = Get-PacoteAppx -Nome $Nome
    if (-not $p.Instalados.Count -and -not $p.Provisionados.Count) {
        return Write-LogOtimizacao -Sessao $Sessao -Item $Item -Alvo $Nome -Resultado JaAplicado -Detalhe 'Não instalado.' | Out-Null
    }
    $ref = $p.Instalados | Select-Object -First 1
    $exib = if ($ref) { Get-NomeExibicaoAppx -Pacote $ref } else { [pscustomobject]@{ Nome = $Nome; Fabricante = $null } }
    $alvo = if ($exib.Nome -ne $Nome) { "$Nome ($($exib.Nome))" } else { $Nome }
    $motivo = if (@($p.Instalados | Where-Object { $_.NonRemovable -or $_.IsFramework -or [string]$_.SignatureKind -eq 'System' }).Count) { 'Pacote do sistema, framework ou não removível.' }
    else { Get-MotivoProibido -Programa ([pscustomobject]@{ Nome = $exib.Nome; Id = $Nome; Fabricante = $exib.Fabricante }) -Perfil $Perfil -A2:($Item -eq 'A2') }
    if ($motivo) { return Write-LogOtimizacao -Sessao $Sessao -Item $Item -Alvo $alvo -Resultado Pulado -Detalhe $motivo | Out-Null }
    if (-not $Loja) {
        return Write-LogOtimizacao -Sessao $Sessao -Item $Item -Alvo $alvo -Resultado Pulado -Detalhe 'Microsoft Store não instalada: não haveria como reinstalar.' | Out-Null
    }

    # PackageFamilyName: do pacote instalado ou, só provisionado, do nome completo (Nome_Versão_Arquitetura_Recurso_Editor).
    $pfn = if ($ref) { $ref.PackageFamilyName } else { $partes = $p.Provisionados[0].PackageName -split '_'; "$($partes[0])_$($partes[-1])" }
    $antes = @(@($p.Instalados | ForEach-Object { $_.PackageFullName }) + @($p.Provisionados | ForEach-Object { "provisionado: $($_.PackageName)" }))
    $mb = ($p.Instalados | ForEach-Object { Get-TamanhoMB $_.InstallLocation } | Measure-Object -Sum).Sum
    $usuarios = @($p.Instalados | ForEach-Object { $_.PackageUserInformation } | Where-Object { $_ } | ForEach-Object { [string]$_.UserSecurityId.Username } | Select-Object -Unique)
    $detalhe = '{0} MB; instalado para: {1}' -f $mb, $(if ($usuarios.Count) { $usuarios -join ', ' } else { 'nenhum usuário (só provisionado)' })
    if ($Sessao.Simular) {
        return Write-LogOtimizacao -Sessao $Sessao -Item $Item -Alvo $alvo -ValorAnterior $antes -ValorNovo 'removido' -Resultado Simulado -Detalhe $detalhe | Out-Null
    }

    Add-EstadoOriginal -Sessao $Sessao -Entrada @{
        Tipo = 'AppxRemovido'; Item = $Item; Nome = $Nome; NomeExibicao = $exib.Nome; Pfn = $pfn
        Versao = if ($ref) { [string]$ref.Version } else { $null }; Pacotes = $antes; Usuarios = $usuarios
    }
    # Provisionamento primeiro: medido na VM 26300, Remove-AppxProvisionedPackage logo após Remove-AppxPackage -AllUsers
    # falhou com 0x80070002 (arquivo não encontrado); na ordem inversa as duas remoções concluem.
    foreach ($v in $p.Provisionados) { Remove-AppxProvisionedPackage -Online -PackageName $v.PackageName -ErrorAction Stop | Out-Null }
    foreach ($i in $p.Instalados) { Remove-AppxPackage -Package $i.PackageFullName -AllUsers -ErrorAction Stop }
    $resta = Get-PacoteAppx -Nome $Nome
    if ($resta.Instalados.Count -or $resta.Provisionados.Count) { throw "O pacote $Nome continua presente após a remoção." }
    Write-LogOtimizacao -Sessao $Sessao -Item $Item -Alvo $alvo -ValorAnterior $antes -ValorNovo 'removido' -Resultado OK -Detalhe "$detalhe. Reversão: Microsoft Store, buscar '$($exib.Nome)'." | Out-Null
}

function Invoke-A1 {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Parâmetros usados no scriptblock passado a Invoke-ItemOtimizacao.')]
    param($Sessao, $Perfil, [bool]$Loja, [string[]]$Lista = $script:ListaA1)
    foreach ($nome in $Lista) {
        Invoke-ItemOtimizacao -Sessao $Sessao -Id 'A1' -Acao { Remove-PacoteAppx -Sessao $Sessao -Item 'A1' -Nome $nome -Perfil $Perfil -Loja $Loja }
    }
}

function Invoke-A4 {
    param($Sessao, $Perfil, [bool]$Loja)
    Remove-PacoteAppx -Sessao $Sessao -Item 'A4' -Nome $script:PacoteA4 -Perfil $Perfil -Loja $Loja
}

#endregion

#region A2 programas do fabricante

$script:ChavesUninstall = @(
    @{ Caminho = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; Escopo = 'Maquina' }
    @{ Caminho = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; Escopo = 'Maquina32' }
)

function Get-ProgramaMaquina {
    <# Programas da máquina (registro Uninstall) e apps Appx que não são do sistema, no formato da seção Programas da Coleta. #>
    foreach ($c in $script:ChavesUninstall) { Get-ProgramaRegistro -Caminho $c.Caminho -Escopo $c.Escopo }
    Get-AppxPackage -AllUsers -ErrorAction Stop | Where-Object { -not $_.IsFramework -and -not $_.IsResourcePackage } |
        Group-Object -Property Name | ForEach-Object {
            $p = $_.Group | Select-Object -First 1
            $exib = Get-NomeExibicaoAppx -Pacote $p
            [pscustomobject]@{ Nome = $exib.Nome; Fabricante = $exib.Fabricante; Versao = [string]$p.Version; Tipo = 'Appx'; Id = $p.Name; Escopo = 'Appx'; Desinstalar = $null }
        }
}

function Test-ProdutoMsiPresente {
    param([Parameter(Mandatory)][string]$ProductCode)
    foreach ($c in $script:ChavesUninstall) { if (Test-Path -LiteralPath "$($c.Caminho)\$ProductCode") { return $true } }
    $false
}

function Invoke-Msiexec {
    <# Executa msiexec e devolve o código de saída. #>
    param([Parameter(Mandatory)][string[]]$Argumentos)
    $proc = Start-Process -FilePath "$env:windir\System32\msiexec.exe" -ArgumentList $Argumentos -Wait -PassThru -WindowStyle Hidden
    $proc.ExitCode
}

function Remove-ProgramaMsi {
    <#
        msiexec /x silencioso. Códigos: learn.microsoft.com/windows/win32/msi/error-codes
        (0 sucesso, 3010 reiniciar para concluir, 1605 produto não instalado, 1618 outra instalação em andamento).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Simulação via Sessao.Simular, derivado de -WhatIf.')]
    param($Sessao, $Programa)
    $pc = $Programa.Id
    # Fora do formato, o msiexec abre a janela de ajuda e espera para sempre, mesmo com /qn.
    if ($pc -notmatch '^\{[0-9A-Fa-f-]{36}\}$') { throw "ProductCode fora do formato {GUID}: $pc" }
    $alvo = "$($Programa.Nome) $($Programa.Versao) $pc"
    $mb = if ($null -ne $Programa.TamanhoMB) { "$($Programa.TamanhoMB) MB" } else { 'tamanho não informado' }
    if ($Sessao.Simular) {
        return Write-LogOtimizacao -Sessao $Sessao -Item 'A2' -Alvo $alvo -ValorAnterior 'instalado' -ValorNovo 'removido' -Resultado Simulado -Detalhe "msiexec /x $pc /qn /norestart; $mb" | Out-Null
    }
    Add-EstadoOriginal -Sessao $Sessao -Entrada @{
        Tipo = 'MsiRemovido'; Item = 'A2'; Nome = $Programa.Nome; Versao = $Programa.Versao; Fabricante = $Programa.Fabricante; ProductCode = $pc
    }
    $logMsi = Join-Path $Sessao.Pasta ('msiexec-{0}.log' -f ($pc -replace '[{}]', ''))
    $codigo = Invoke-Msiexec -Argumentos @('/x', $pc, '/qn', '/norestart', '/l*v', "`"$logMsi`"")
    switch ($codigo) {
        { $_ -in 0, 3010 } {
            if (Test-ProdutoMsiPresente -ProductCode $pc) { throw "msiexec retornou $codigo, mas o produto continua registrado. Log: $logMsi" }
            $det = if ($codigo -eq 3010) { "Reinicialização necessária para concluir (3010). $mb." } else { "$mb." }
            Write-LogOtimizacao -Sessao $Sessao -Item 'A2' -Alvo $alvo -ValorAnterior 'instalado' -ValorNovo 'removido' -Resultado OK -Detalhe "$det Reversão: reinstalar com o instalador do fabricante." | Out-Null
        }
        1605 { Write-LogOtimizacao -Sessao $Sessao -Item 'A2' -Alvo $alvo -Resultado JaAplicado -Detalhe 'Windows Installer: produto não instalado (1605).' | Out-Null }
        1618 { throw 'Outra instalação em andamento (1618). Repetir depois.' }
        default { throw "msiexec retornou $codigo. Log: $logMsi" }
    }
}

function Invoke-A2 {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Parâmetros usados no scriptblock passado a Invoke-ItemOtimizacao.')]
    param($Sessao, $Perfil, [bool]$Loja)
    $padroes = @(Get-Opcao $Perfil 'A2Remover' | Where-Object { $_ })
    if (-not $padroes.Count) {
        return Write-LogOtimizacao -Sessao $Sessao -Item 'A2' -Resultado Pulado -Detalhe 'Defina Opcoes.A2Remover no perfil com os nomes da seção Programas da Coleta.' | Out-Null
    }
    $programas = @(Get-ProgramaMaquina)
    foreach ($padrao in $padroes) {
        $achados = @($programas | Where-Object { $_.Nome -like $padrao -or $_.Id -like $padrao })
        if (-not $achados.Count) {
            Write-LogOtimizacao -Sessao $Sessao -Item 'A2' -Alvo $padrao -Resultado JaAplicado -Detalhe 'Não encontrado entre os programas da máquina: já removido, nome diferente do mostrado na Coleta ou instalado só no perfil de um usuário (remoção manual).' | Out-Null
            continue
        }
        foreach ($prog in $achados) {
            Invoke-ItemOtimizacao -Sessao $Sessao -Id 'A2' -Acao {
                if ($prog.Tipo -eq 'Appx') { return Remove-PacoteAppx -Sessao $Sessao -Item 'A2' -Nome $prog.Id -Perfil $Perfil -Loja $Loja }
                $alvo = "$($prog.Nome) $($prog.Versao)"
                $motivo = Get-MotivoProibido -Programa $prog -Perfil $Perfil -A2
                if ($motivo) { return Write-LogOtimizacao -Sessao $Sessao -Item 'A2' -Alvo $alvo -Resultado Pulado -Detalhe $motivo | Out-Null }
                if ($prog.Tipo -eq 'MSI') { return Remove-ProgramaMsi -Sessao $Sessao -Programa $prog }
                Write-Achado -Sessao $Sessao -Item 'A2' -Alvo $alvo -ValorAnterior 'instalado' -Detalhe "Instalador EXE: remover manualmente em Configurações > Aplicativos. Desinstalador: $($prog.Desinstalar)"
            }
        }
    }
}

#endregion

#region Reversão (conferência)

function Get-ManipuladorReversao {
    <# Não reinstalam: conferem se o item voltou e orientam a reinstalação manual. #>
    @{
        AppxRemovido = {
            param($e, $Sessao)
            $alvo = "$($e.Nome) ($($e.NomeExibicao))"
            if ($Sessao.Simular) { return Write-LogOtimizacao -Sessao $Sessao -Item $e.Item -Alvo $alvo -ValorNovo 'conferir se foi reinstalado' -Resultado Simulado }
            $atual = @(Get-AppxPackage -AllUsers -Name $e.Nome -ErrorAction Stop)
            if ($atual.Count) {
                return Write-LogOtimizacao -Sessao $Sessao -Item $e.Item -Alvo $alvo -ValorAnterior 'removido' -ValorNovo "instalado $($atual[0].Version)" -Resultado Revertido
            }
            Write-LogOtimizacao -Sessao $Sessao -Item $e.Item -Alvo $alvo -ValorAnterior 'removido' -Resultado Pulado -Detalhe "Reinstalar pela Microsoft Store na conta do usuário: buscar '$($e.NomeExibicao)' ou abrir ms-windows-store://pdp/?PFN=$($e.Pfn). Depois, conferir com -Revert -Sessao <pasta da aplicação>."
        }
        MsiRemovido  = {
            param($e, $Sessao)
            $alvo = "$($e.Nome) $($e.Versao) $($e.ProductCode)"
            if ($Sessao.Simular) { return Write-LogOtimizacao -Sessao $Sessao -Item $e.Item -Alvo $alvo -ValorNovo 'conferir se foi reinstalado' -Resultado Simulado }
            if (Test-ProdutoMsiPresente -ProductCode $e.ProductCode) {
                return Write-LogOtimizacao -Sessao $Sessao -Item $e.Item -Alvo $alvo -ValorAnterior 'removido' -ValorNovo 'instalado' -Resultado Revertido
            }
            Write-LogOtimizacao -Sessao $Sessao -Item $e.Item -Alvo $alvo -ValorAnterior 'removido' -Resultado Pulado -Detalhe "Reinstalar com o instalador do fabricante ($($e.Fabricante)). Depois, conferir com -Revert -Sessao <pasta da aplicação>."
        }
    }
}

#endregion

#region Execução

function Invoke-Aplicativo {
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

    $itens = Get-ItemPerfil -Perfil $p -Prefixo 'A'
    if ($itens -contains 'A3') {
        Write-LogOtimizacao -Sessao $s -Item 'A3' -Alvo 'OneDrive' -Resultado Pulado -Detalhe 'OneDrive não é removido. Para tirá-lo da inicialização, use o I1 (Inicializacao).' | Out-Null
    }
    if (-not @($itens | Where-Object { $_ -in 'A1', 'A2', 'A4' }).Count) { Write-Warning 'Nenhum item A1, A2 ou A4 no perfil. Nada a fazer.'; return $s }
    $info = Get-InfoWindows
    $loja = Test-LojaDisponivel
    Write-LogOtimizacao -Sessao $s -Item 'Contexto' -Alvo 'Windows' -ValorNovo "$($info.EditionId) $($info.Build).$($info.UBR)" -Resultado Info -Detalhe "Executado por $env:USERDOMAIN\$env:USERNAME; Microsoft Store instalada: $loja" | Out-Null

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

    if ($itens -contains 'A4') { Invoke-ItemOtimizacao -Sessao $s -Id 'A4' -Acao { Invoke-A4 -Sessao $s -Perfil $p -Loja $loja } }
    if ($itens -contains 'A1') { Invoke-ItemOtimizacao -Sessao $s -Id 'A1' -Acao { Invoke-A1 -Sessao $s -Perfil $p -Loja $loja } }
    if ($itens -contains 'A2') { Invoke-ItemOtimizacao -Sessao $s -Id 'A2' -Acao { Invoke-A2 -Sessao $s -Perfil $p -Loja $loja } }
    $s
}

# Permite carregar as funções com dot-source (testes) sem executar.
if ($MyInvocation.InvocationName -ne '.') {
    $s = Invoke-Aplicativo -Perfil $Perfil -Revert:$Revert -Sessao $Sessao -PermitirReinicializacaoPendente:$PermitirReinicializacaoPendente -Simular:([bool]$WhatIfPreference)
    if ($s) {
        # Na tela, valores longos (lista de pacotes) são encurtados: sem isso o Format-Table descarta as colunas Resultado e Detalhe.
        # O log.csv da sessão guarda os valores completos.
        $curto = { param($v) if ($v.Length -gt 60) { $v.Substring(0, 57) + '...' } else { $v } }
        $s.Linhas | Format-Table -Property Item, Alvo, @{ n = 'ValorAnterior'; e = { & $curto $_.ValorAnterior } }, @{ n = 'ValorNovo'; e = { & $curto $_.ValorNovo } }, Resultado, Detalhe -AutoSize -Wrap | Out-String -Width 220
        Get-ResumoSessao -Sessao $s | Format-Table -AutoSize | Out-String
        if ($s.Pasta) { "Sessão: $($s.Pasta)" }
        if (@($s.Linhas | Where-Object Resultado -eq 'Falha').Count) { exit 1 }
    }
}

#endregion
