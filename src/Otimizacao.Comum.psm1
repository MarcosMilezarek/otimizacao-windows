<#
.SYNOPSIS
    Funções comuns aos scripts de otimização: privilégio, versão do Windows, reinicialização pendente e acesso ao HKCU do usuário alvo.

.DESCRIPTION
    Módulo carregado pelos scripts de src\. Não altera o sistema, exceto Invoke-NoHiveUsuario, que carrega
    temporariamente o NTUSER.DAT do usuário alvo quando ele não está conectado e o descarrega ao final.
    Compatível com Windows PowerShell 5.1. Não depende do idioma do Windows.
#>

Set-StrictMode -Version 2.0

function Test-Administrador {
    <#
    .SYNOPSIS
        Verdadeiro se o processo atual está elevado como administrador.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-InfoWindows {
    <#
    .SYNOPSIS
        Edição, versão e build do Windows lidos do registro e do WMI, sem depender de texto localizado.
    #>
    [CmdletBinding()]
    param()
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $os = Get-CimInstance Win32_OperatingSystem
    $build = [int]$cv.CurrentBuildNumber
    [pscustomobject]@{
        Produto          = $os.Caption
        Familia          = if ($build -ge 22000) { 'Windows 11' } else { 'Windows 10' }
        EditionId        = $cv.EditionID
        DisplayVersion   = if ($cv.PSObject.Properties['DisplayVersion']) { $cv.DisplayVersion } else { $cv.ReleaseId }
        Build            = $build
        UBR              = [int]$cv.UBR
        Arquitetura      = $os.OSArchitecture
        IdiomaSO         = [int]$os.OSLanguage
        InstallationType = $cv.InstallationType
        Instalado        = $os.InstallDate
        UltimoBoot       = $os.LastBootUpTime
    }
}

function Test-ReinicializacaoPendente {
    <#
    .SYNOPSIS
        Indicadores de reinicialização pendente: servicing (CBS), Windows Update e renomeação de arquivos.
    #>
    [CmdletBinding()]
    param()
    $sm = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction SilentlyContinue
    [pscustomobject]@{
        ComponentBasedServicing = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
        WindowsUpdate           = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
        RenomeacaoArquivos      = [bool]($sm -and $sm.PSObject.Properties['PendingFileRenameOperations'] -and $sm.PendingFileRenameOperations)
    }
}

function Get-TipoEquipamento {
    <#
    .SYNOPSIS
        Notebook ou Desktop pelos ChassisTypes do SMBIOS (Win32_SystemEnclosure) e pela presença de bateria.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    # 8 Portable, 9 Laptop, 10 Notebook, 11 Hand Held, 14 Sub Notebook, 30 Tablet, 31 Convertible, 32 Detachable
    $portateis = 8, 9, 10, 11, 14, 30, 31, 32
    $chassis = @((Get-CimInstance Win32_SystemEnclosure).ChassisTypes)
    $bateria = @(Get-CimInstance Win32_Battery).Count -gt 0
    if ($bateria -or @($chassis | Where-Object { $portateis -contains $_ }).Count) { 'Notebook' } else { 'Desktop' }
}

if (-not ('Otimizacao.Mdm' -as [type])) {
    Add-Type -Namespace Otimizacao -Name Mdm -MemberDefinition @'
[DllImport("mdmregistration.dll")] public static extern int IsDeviceRegisteredWithManagement(out bool registrado, int cchUPN, System.Text.StringBuilder upn);
'@
}

function Test-GerenciadoMdm {
    <#
    .SYNOPSIS
        Verdadeiro se o dispositivo está registrado num serviço MDM (Intune ou outro).
    .DESCRIPTION
        Usa IsDeviceRegisteredWithManagement (mdmregistration.dll, Windows 8.1+):
        learn.microsoft.com/windows/win32/api/mdmregistration/nf-mdmregistration-isdeviceregisteredwithmanagement
        Não conta as inscrições internas do Windows em HKLM\SOFTWARE\Microsoft\Enrollments (Local, Cloud e
        Deploy Authority), presentes mesmo sem gerenciamento.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $registrado = $false
    $hr = [Otimizacao.Mdm]::IsDeviceRegisteredWithManagement([ref]$registrado, 0, $null)
    if ($hr -ne 0) { throw ('IsDeviceRegisteredWithManagement falhou (0x{0:X8}).' -f $hr) }
    $registrado
}

function Get-UsuarioAlvo {
    <#
    .SYNOPSIS
        Resolve o SID e o perfil do usuário cujo HKCU deve ser lido ou alterado.
        Sem -Sid, usa o usuário da sessão de console (pode diferir da conta elevada que executa o script).
    #>
    [CmdletBinding()]
    param([string]$Sid)

    if (-not $Sid) {
        $conta = (Get-CimInstance Win32_ComputerSystem).UserName
        if (-not $conta) {
            throw 'Nenhum usuário conectado ao console. Informe o SID do usuário alvo.'
        }
        $Sid = ([Security.Principal.NTAccount]$conta).Translate([Security.Principal.SecurityIdentifier]).Value
    }
    $chave = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$Sid"
    if (-not (Test-Path $chave)) {
        throw "Perfil não encontrado para o SID $Sid."
    }
    [pscustomobject]@{
        Sid    = $Sid
        Perfil = (Get-ItemProperty $chave).ProfileImagePath
    }
}

function Invoke-NoHiveUsuario {
    <#
    .SYNOPSIS
        Executa ScriptBlock recebendo como argumento a raiz do registro do usuário alvo (Registry::HKEY_USERS\...).
        Se o hive não estiver carregado (usuário desconectado), carrega o NTUSER.DAT, executa e descarrega.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Sid,
        [Parameter(Mandatory)][string]$Perfil,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )

    $raiz = "Registry::HKEY_USERS\$Sid"
    if (Test-Path $raiz) {
        return & $ScriptBlock $raiz
    }

    if (-not (Test-Administrador)) {
        throw "O hive do usuário $Sid não está carregado e carregá-lo exige administrador."
    }
    $nome = 'Otimizacao_' + ($Sid -replace '[^0-9A-Za-z]', '_')
    $ntuser = Join-Path $Perfil 'NTUSER.DAT'
    & reg.exe load "HKU\$nome" $ntuser 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Falha ao carregar $ntuser (código $LASTEXITCODE)."
    }
    try {
        & $ScriptBlock "Registry::HKEY_USERS\$nome"
    }
    finally {
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        & reg.exe unload "HKU\$nome" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Não foi possível descarregar HKU\$nome (código $LASTEXITCODE). Será liberado na próxima reinicialização."
        }
    }
}

#region Perfil do cliente

$script:RaizBackup = Join-Path $env:ProgramData 'Otimizacao'

function Import-PerfilCliente {
    <#
    .SYNOPSIS
        Lê o perfil .psd1 do cliente (sem executar código) e valida os campos.
    .DESCRIPTION
        Campos: Cliente (obrigatório), UsuarioSid, Aplicar (IDs do catálogo, ex. 'L1'), Pular,
        Protegidos (hashtable: categoria -> lista de nomes com curinga), Opcoes (hashtable livre por script).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Caminho)
    if (-not (Test-Path -LiteralPath $Caminho)) { throw "Perfil não encontrado: $Caminho" }
    $d = Import-PowerShellDataFile -LiteralPath $Caminho
    if (-not $d.ContainsKey('Cliente') -or [string]$d.Cliente -notmatch '^[\w.-]{1,60}$') {
        throw 'Perfil inválido: Cliente é obrigatório e aceita apenas letras, números, ponto, hífen e sublinhado.'
    }
    $aplicar = if ($d.ContainsKey('Aplicar')) { @($d.Aplicar) } else { @() }
    $pular = if ($d.ContainsKey('Pular')) { @($d.Pular) } else { @() }
    foreach ($id in $aplicar + $pular) {
        if ([string]$id -notmatch '^[A-Z]\d{1,2}$') { throw "Perfil inválido: item '$id' fora do padrão do catálogo." }
    }
    [pscustomobject]@{
        Cliente    = [string]$d.Cliente
        UsuarioSid = if ($d.ContainsKey('UsuarioSid')) { [string]$d.UsuarioSid } else { $null }
        Aplicar    = $aplicar
        Pular      = $pular
        Protegidos = if ($d.ContainsKey('Protegidos')) { $d.Protegidos } else { @{} }
        Opcoes     = if ($d.ContainsKey('Opcoes')) { $d.Opcoes } else { @{} }
    }
}

function Get-ItemPerfil {
    <#
    .SYNOPSIS
        IDs do perfil a aplicar para um script (prefixo do catálogo), descontando os itens em Pular.
    #>
    [CmdletBinding()]
    [OutputType([System.Array])]
    param([Parameter(Mandatory)]$Perfil, [Parameter(Mandatory)][string]$Prefixo)
    @($Perfil.Aplicar | Where-Object { $_ -like "$Prefixo*" -and $Perfil.Pular -notcontains $_ })
}

function Test-Protegido {
    <#
    .SYNOPSIS
        Verdadeiro se Nome casa com algum padrão da categoria em Protegidos do perfil.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$Perfil, [Parameter(Mandatory)][string]$Categoria, [string]$Nome)
    if (-not $Nome -or -not $Perfil.Protegidos.ContainsKey($Categoria)) { return $false }
    foreach ($padrao in @($Perfil.Protegidos[$Categoria])) { if ($Nome -like $padrao) { return $true } }
    $false
}

#endregion

#region Pré-checagens e ponto de restauração

function Test-PreCondicao {
    <#
    .SYNOPSIS
        Pré-checagens comuns aos scripts que alteram o sistema. Retorna Bloqueios (impedem a execução) e Avisos.
    #>
    [CmdletBinding()]
    param(
        [switch]$PermitirReinicializacaoPendente,
        [double]$EspacoMinimoGB = 2,
        [int]$BateriaMinimaPct = 40
    )
    $bloqueios = New-Object System.Collections.Generic.List[string]
    $avisos = New-Object System.Collections.Generic.List[string]

    if (-not (Test-Administrador)) { $bloqueios.Add('Execute como administrador.') }

    $r = Test-ReinicializacaoPendente
    if ($r.ComponentBasedServicing -or $r.WindowsUpdate -or $r.RenomeacaoArquivos) {
        $msg = 'Reinicialização pendente. Reinicie antes de otimizar.'
        if ($PermitirReinicializacaoPendente) { $avisos.Add($msg) } else { $bloqueios.Add($msg) }
    }

    $vol = Get-Volume -DriveLetter $env:SystemDrive.Substring(0, 1)
    $livre = [math]::Round($vol.SizeRemaining / 1GB, 1)
    if ($livre -lt $EspacoMinimoGB) {
        $bloqueios.Add("Espaço livre em $env:SystemDrive ($livre GB) abaixo de $EspacoMinimoGB GB: o ponto de restauração pode falhar.")
    }

    $baterias = @(Get-CimInstance Win32_Battery)
    # BatteryStatus 2 = com acesso à rede elétrica
    if ($baterias.Count -and @($baterias | Where-Object { $_.BatteryStatus -ne 2 }).Count) {
        $carga = ($baterias | Measure-Object -Property EstimatedChargeRemaining -Minimum).Minimum
        if ($carga -lt $BateriaMinimaPct) { $bloqueios.Add("Notebook na bateria com $carga%. Conecte à tomada.") }
        else { $avisos.Add("Notebook na bateria ($carga%). Recomendado conectar à tomada.") }
    }

    # Instalação em andamento pela API do Windows Update (IUpdateInstaller.IsBusy,
    # learn.microsoft.com/windows/win32/api/wuapi/nf-wuapi-iupdateinstaller-get_isbusy) e SetupHost (atualização de versão).
    # TiWorker sozinho não basta: sobe em qualquer consulta ao servicing (DISM, Get-WindowsOptionalFeature, varredura do WU)
    # e fica ativo minutos (medido na VM: 120 s após Get-WindowsOptionalFeature, com IsBusy falso).
    if (Get-Process -Name SetupHost -ErrorAction SilentlyContinue) {
        $bloqueios.Add('Atualização de versão do Windows em andamento (SetupHost). Aguarde terminar.')
    }
    $tiWorker = [bool](Get-Process -Name TiWorker -ErrorAction SilentlyContinue)
    try {
        if ((New-Object -ComObject Microsoft.Update.Installer).IsBusy) {
            $bloqueios.Add('Instalação ou desinstalação de atualização em andamento (Windows Update). Aguarde terminar.')
        }
        elseif ($tiWorker) { $avisos.Add('Serviço de manutenção do Windows ativo (TiWorker), sem instalação em andamento pelo Windows Update.') }
    }
    catch {
        if ($tiWorker) { $bloqueios.Add('Manutenção do Windows ativa (TiWorker) e estado do Windows Update não verificado. Aguarde terminar.') }
    }

    $cs = Get-CimInstance Win32_ComputerSystem
    if ($cs.PartOfDomain) { $avisos.Add("Máquina no domínio $($cs.Domain): valores já definidos por política serão pulados.") }
    try {
        if (Test-GerenciadoMdm) { $avisos.Add('Máquina registrada em gerenciamento MDM: valores já definidos por política serão pulados.') }
    }
    catch { $avisos.Add("Gerenciamento MDM não verificado: $($_.Exception.Message)") }

    try {
        $bl = @(Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -ErrorAction Stop |
                Where-Object { $_.ProtectionStatus -eq 1 })
        if ($bl.Count) { $avisos.Add('BitLocker ativo: nenhum item altera o BitLocker. Tenha a chave de recuperação antes de mexer em BIOS.') }
    }
    catch { Write-Verbose "BitLocker não consultado: $($_.Exception.Message)" }

    [pscustomobject]@{ Bloqueios = $bloqueios.ToArray(); Avisos = $avisos.ToArray() }
}

function New-PontoRestauracao {
    <#
    .SYNOPSIS
        Cria um ponto de restauração e confirma que ele existe. Lança erro se não for criado.
    .DESCRIPTION
        O Windows ignora a criação se houve outro ponto dentro de SystemRestorePointCreationFrequency minutos
        (padrão 1440). Nesse caso o valor é zerado só durante a criação e restaurado em seguida.
        Fonte: learn.microsoft.com/windows/win32/sr/createrestorepoint-systemrestore
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Simulação decidida pelo script chamador; o módulo não herda -WhatIf.')]
    param([Parameter(Mandatory)][string]$Descricao)

    $chave = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $nomeFreq = 'SystemRestorePointCreationFrequency'
    $antes = @(Get-ComputerRestorePoint -ErrorAction SilentlyContinue)
    $seqAntes = if ($antes.Count) { ($antes | Measure-Object -Property SequenceNumber -Maximum).Maximum } else { 0 }
    $freqAtual = Get-ValorRegistro -Caminho $chave -Nome $nomeFreq
    $janela = if ($freqAtual.Existe) { [int]$freqAtual.Valor } else { 1440 }
    $alterou = $false
    try {
        $ultimo = $antes | Sort-Object -Property SequenceNumber | Select-Object -Last 1
        if ($ultimo -and $janela -gt 0) {
            $criado = [Management.ManagementDateTimeConverter]::ToDateTime($ultimo.CreationTime)
            if (((Get-Date) - $criado).TotalMinutes -lt $janela) {
                New-ItemProperty -Path $chave -Name $nomeFreq -Value 0 -PropertyType DWord -Force | Out-Null
                $alterou = $true
            }
        }
        Checkpoint-Computer -Description $Descricao -RestorePointType MODIFY_SETTINGS -ErrorAction Stop -WarningAction SilentlyContinue
    }
    catch {
        throw "Ponto de restauração não criado ($($_.Exception.Message)). Verifique se a Proteção do Sistema está ativada na unidade do sistema."
    }
    finally {
        if ($alterou) {
            if ($freqAtual.Existe) { New-ItemProperty -Path $chave -Name $nomeFreq -Value $freqAtual.Valor -PropertyType DWord -Force | Out-Null }
            else { Remove-ItemProperty -Path $chave -Name $nomeFreq -ErrorAction SilentlyContinue }
        }
    }
    $novo = @(Get-ComputerRestorePoint -ErrorAction SilentlyContinue) | Where-Object { $_.SequenceNumber -gt $seqAntes } | Select-Object -Last 1
    if (-not $novo) {
        throw 'O ponto de restauração não foi criado. Verifique se a Proteção do Sistema está ativada na unidade do sistema.'
    }
    $novo
}

#endregion

#region Sessão, log e estado original

function New-SessaoOtimizacao {
    <#
    .SYNOPSIS
        Cria a sessão de execução. Com -Simular, nada é gravado em disco (log só na saída).
        Pasta: %ProgramData%\Otimizacao\<Cliente>\<yyyyMMdd-HHmmss>-<Script>.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Com -Simular não grava nada.')]
    param(
        [Parameter(Mandatory)][string]$Cliente,
        [Parameter(Mandatory)][string]$Script,
        [switch]$Simular,
        [string]$Raiz = $script:RaizBackup
    )
    $pasta = $null
    if (-not $Simular) {
        $pasta = Join-Path (Join-Path $Raiz $Cliente) ('{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $Script)
        New-Item -ItemType Directory -Path $pasta -Force | Out-Null
    }
    [pscustomobject]@{
        Simular  = [bool]$Simular
        Pasta    = $pasta
        Log      = if ($pasta) { Join-Path $pasta 'log.csv' } else { $null }
        Estado   = if ($pasta) { Join-Path $pasta 'estado-original.json' } else { $null }
        Entradas = New-Object System.Collections.Generic.List[object]
        Linhas   = New-Object System.Collections.Generic.List[object]
    }
}

function ConvertTo-TextoLog {
    param($Valor)
    if ($null -eq $Valor) { return '' }
    if ($Valor -is [byte[]]) { return ($Valor | ForEach-Object { $_.ToString('X2') }) -join ' ' }
    if ($Valor -is [array]) { return ($Valor | ForEach-Object { [string]$_ }) -join '; ' }
    [string]$Valor
}

function Write-LogOtimizacao {
    <#
    .SYNOPSIS
        Registra uma linha (data, item, alvo, valor anterior, valor novo, resultado, detalhe) no log.csv da sessão e na saída.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Sessao,
        [Parameter(Mandatory)][string]$Item,
        [string]$Alvo,
        $ValorAnterior,
        $ValorNovo,
        [Parameter(Mandatory)][ValidateSet('OK', 'JaAplicado', 'Pulado', 'Falha', 'Simulado', 'Revertido', 'Info')][string]$Resultado,
        [string]$Detalhe
    )
    $linha = [pscustomobject]@{
        Data          = (Get-Date).ToString('s')
        Item          = $Item
        Alvo          = $Alvo
        ValorAnterior = ConvertTo-TextoLog $ValorAnterior
        ValorNovo     = ConvertTo-TextoLog $ValorNovo
        Resultado     = $Resultado
        Detalhe       = $Detalhe
    }
    $Sessao.Linhas.Add($linha)
    if ($Sessao.Log) { $linha | Export-Csv -LiteralPath $Sessao.Log -Append -NoTypeInformation -Encoding UTF8 }
    if ($Resultado -eq 'Falha') { Write-Warning "[$Item] $Alvo : $Detalhe" }
    $linha
}

function Add-EstadoOriginal {
    <#
    .SYNOPSIS
        Acrescenta uma entrada ao estado original da sessão e regrava o JSON imediatamente (backup antes de alterar).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Sessao, [Parameter(Mandatory)][hashtable]$Entrada)
    $Sessao.Entradas.Add([pscustomobject]$Entrada)
    if ($Sessao.Estado) {
        ConvertTo-Json -InputObject @($Sessao.Entradas.ToArray()) -Depth 6 | Out-File -LiteralPath $Sessao.Estado -Encoding UTF8
    }
}

function Invoke-ItemOtimizacao {
    <#
    .SYNOPSIS
        Executa a ação de um item isolando falhas: um erro é registrado e o lote continua.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Sessao, [Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][scriptblock]$Acao)
    try { & $Acao }
    catch { Write-LogOtimizacao -Sessao $Sessao -Item $Id -Resultado Falha -Detalhe $_.Exception.Message | Out-Null }
}

function Get-ResumoSessao {
    <#
    .SYNOPSIS
        Contagem de resultados por item, para o resumo ao final da execução.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Sessao)
    $Sessao.Linhas | Group-Object -Property Item | ForEach-Object {
        $g = $_.Group
        [pscustomobject]@{
            Item       = $_.Name
            OK         = @($g | Where-Object Resultado -eq 'OK').Count
            JaAplicado = @($g | Where-Object Resultado -eq 'JaAplicado').Count
            Simulado   = @($g | Where-Object Resultado -eq 'Simulado').Count
            Pulado     = @($g | Where-Object Resultado -eq 'Pulado').Count
            Revertido  = @($g | Where-Object Resultado -eq 'Revertido').Count
            Falha      = @($g | Where-Object Resultado -eq 'Falha').Count
        }
    }
}

#endregion

#region Registro com backup e reversão

function Get-ValorRegistro {
    <#
    .SYNOPSIS
        Lê um valor de registro sem expandir variáveis. Indica se a chave e o valor existem e o tipo.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Caminho, [Parameter(Mandatory)][string]$Nome)
    $k = Get-Item -LiteralPath $Caminho -ErrorAction SilentlyContinue
    if (-not $k -or @($k.GetValueNames()) -notcontains $Nome) {
        return [pscustomobject]@{ ChaveExiste = [bool]$k; Existe = $false; Valor = $null; Tipo = $null }
    }
    [pscustomobject]@{
        ChaveExiste = $true
        Existe      = $true
        Valor       = $k.GetValue($Nome, $null, 'DoNotExpandEnvironmentNames')
        Tipo        = [string]$k.GetValueKind($Nome)
    }
}

function Test-ValorIgual {
    <#
    .SYNOPSIS
        Compara valores de registro, inclusive listas (Binary, MultiString), elemento a elemento.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param($A, $B)
    if ($null -eq $A -or $null -eq $B) { return ($null -eq $A -and $null -eq $B) }
    $listaA = $A -is [array]; $listaB = $B -is [array]
    if ($listaA -or $listaB) {
        $a2 = @($A); $b2 = @($B)
        if ($a2.Count -ne $b2.Count) { return $false }
        for ($i = 0; $i -lt $a2.Count; $i++) { if ([string]$a2[$i] -ne [string]$b2[$i]) { return $false } }
        return $true
    }
    [string]$A -eq [string]$B
}

function Get-PrimeiraChaveAusente {
    <# Chave mais alta do caminho que ainda não existe (será criada); $null se a chave final já existe. #>
    param([string]$Raiz, [string]$SubChave)
    $partes = $SubChave.Split('\')
    for ($i = 0; $i -lt $partes.Count; $i++) {
        $parcial = ($partes[0..$i] -join '\')
        if (-not (Test-Path -LiteralPath "$Raiz\$parcial")) { return $parcial }
    }
    $null
}

function ConvertTo-ValorRegistro {
    <# Converte valor lido do JSON de volta ao tipo do registro. #>
    param($Valor, [string]$Tipo)
    switch ($Tipo) {
        'Binary' { [byte[]]@($Valor) }
        'MultiString' { [string[]]@($Valor) }
        'DWord' { [int]$Valor }
        'QWord' { [long]$Valor }
        default { [string]$Valor }
    }
}

function Set-ValorRegistro {
    <#
    .SYNOPSIS
        Define um valor de registro com backup do original, idempotência e leitura de volta.
    .PARAMETER Raiz
        Registry::HKEY_LOCAL_MACHINE para Escopo Maquina, ou a raiz entregue por Invoke-NoHiveUsuario para Escopo Usuario.
    .PARAMETER PularSeDefinido
        Não altera se o valor já existe com outro conteúdo (ex.: definido por GPO).
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Simulação via -Simular da sessão; o módulo não herda -WhatIf.')]
    param(
        [Parameter(Mandatory)]$Sessao,
        [Parameter(Mandatory)][string]$Item,
        [Parameter(Mandatory)][string]$Raiz,
        [Parameter(Mandatory)][string]$SubChave,
        [Parameter(Mandatory)][string]$Nome,
        [Parameter(Mandatory)]$Valor,
        [ValidateSet('DWord', 'QWord', 'String', 'ExpandString', 'Binary', 'MultiString')][string]$Tipo = 'DWord',
        [ValidateSet('Maquina', 'Usuario')][string]$Escopo = 'Maquina',
        [string]$Sid,
        [switch]$PularSeDefinido
    )
    $caminho = "$Raiz\$SubChave"
    $alvo = "$SubChave\$Nome"
    $atual = Get-ValorRegistro -Caminho $caminho -Nome $Nome

    if ($atual.Existe -and $atual.Tipo -eq $Tipo -and (Test-ValorIgual $atual.Valor $Valor)) {
        return Write-LogOtimizacao -Sessao $Sessao -Item $Item -Alvo $alvo -ValorAnterior $atual.Valor -ValorNovo $Valor -Resultado JaAplicado
    }
    if ($PularSeDefinido -and $atual.Existe) {
        return Write-LogOtimizacao -Sessao $Sessao -Item $Item -Alvo $alvo -ValorAnterior $atual.Valor -ValorNovo $Valor -Resultado Pulado -Detalhe 'Valor já definido com outro conteúdo (provável política).'
    }
    if ($Sessao.Simular) {
        return Write-LogOtimizacao -Sessao $Sessao -Item $Item -Alvo $alvo -ValorAnterior $(if ($atual.Existe) { $atual.Valor } else { '(ausente)' }) -ValorNovo $Valor -Resultado Simulado
    }

    Add-EstadoOriginal -Sessao $Sessao -Entrada @{
        Tipo = 'Registro'; Item = $Item; Escopo = $Escopo; Sid = $Sid; SubChave = $SubChave; Nome = $Nome
        Raiz = $(if ($Escopo -eq 'Maquina') { $Raiz } else { $null })
        Existia = $atual.Existe; Valor = $atual.Valor; TipoValor = $atual.Tipo
        PrimeiraCriada = Get-PrimeiraChaveAusente -Raiz $Raiz -SubChave $SubChave
    }
    if (-not $atual.ChaveExiste) { New-Item -Path $caminho -Force | Out-Null }
    New-ItemProperty -LiteralPath $caminho -Name $Nome -Value $Valor -PropertyType $Tipo -Force | Out-Null
    $lido = Get-ValorRegistro -Caminho $caminho -Nome $Nome
    if (-not (Test-ValorIgual $lido.Valor $Valor)) { throw "Leitura de volta divergente em $alvo." }
    Write-LogOtimizacao -Sessao $Sessao -Item $Item -Alvo $alvo -ValorAnterior $(if ($atual.Existe) { $atual.Valor } else { '(ausente)' }) -ValorNovo $Valor -Resultado OK
}

function Restore-ValorRegistro {
    <#
    .SYNOPSIS
        Restaura uma entrada de registro do estado original: valor antigo, ou remoção se não existia
        (incluindo chaves criadas pelo script que ficaram vazias).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Sessao, [Parameter(Mandatory)]$Entrada, [Parameter(Mandatory)][string]$Raiz)
    $caminho = "$Raiz\$($Entrada.SubChave)"
    $alvo = "$($Entrada.SubChave)\$($Entrada.Nome)"
    $atual = Get-ValorRegistro -Caminho $caminho -Nome $Entrada.Nome
    $anterior = if ($Entrada.Existia) { ConvertTo-ValorRegistro $Entrada.Valor $Entrada.TipoValor } else { '(ausente)' }

    if ($Sessao.Simular) {
        return Write-LogOtimizacao -Sessao $Sessao -Item $Entrada.Item -Alvo $alvo -ValorAnterior $atual.Valor -ValorNovo $anterior -Resultado Simulado
    }
    if ($Entrada.Existia) {
        if (-not $atual.ChaveExiste) { New-Item -Path $caminho -Force | Out-Null }
        New-ItemProperty -LiteralPath $caminho -Name $Entrada.Nome -Value $anterior -PropertyType $Entrada.TipoValor -Force | Out-Null
        if (-not (Test-ValorIgual (Get-ValorRegistro -Caminho $caminho -Nome $Entrada.Nome).Valor $anterior)) { throw "Reversão divergente em $alvo." }
    }
    else {
        if ($atual.Existe) { Remove-ItemProperty -LiteralPath $caminho -Name $Entrada.Nome }
        if ($Entrada.PrimeiraCriada) {
            $limite = "$Raiz\$($Entrada.PrimeiraCriada)"
            $chave = $caminho
            while ($chave.Length -ge $limite.Length -and (Test-Path -LiteralPath $chave)) {
                $k = Get-Item -LiteralPath $chave
                if ($k.SubKeyCount -or $k.ValueCount) { break }
                Remove-Item -LiteralPath $chave
                $chave = Split-Path -Path $chave -Parent
            }
        }
        if ((Get-ValorRegistro -Caminho $caminho -Nome $Entrada.Nome).Existe) { throw "Reversão divergente em $alvo." }
    }
    Write-LogOtimizacao -Sessao $Sessao -Item $Entrada.Item -Alvo $alvo -ValorAnterior $atual.Valor -ValorNovo $anterior -Resultado Revertido
}

function Get-SessaoParaReverter {
    <#
    .SYNOPSIS
        Lê o estado original gravado numa pasta de sessão.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Cliente, Script e Raiz mantidos na assinatura usada pelos scripts e testes.')]
    param(
        [Parameter(Mandatory)][string]$Cliente,
        [Parameter(Mandatory)][string]$Script,
        [Parameter(Mandatory)][string]$Pasta,
        [string]$Raiz = $script:RaizBackup
    )
    $arquivo = Join-Path $Pasta 'estado-original.json'
    $entradas = if (Test-Path -LiteralPath $arquivo) { @(Get-Content -LiteralPath $arquivo -Raw -Encoding UTF8 | ConvertFrom-Json) } else { @() }
    [pscustomobject]@{ Pasta = $Pasta; Entradas = $entradas }
}

function Invoke-Reversao {
    <#
    .SYNOPSIS
        Reverte as entradas na ordem inversa da aplicação. Registro é tratado aqui; outros tipos
        (serviço, tarefa etc.) por Manipuladores: hashtable Tipo -> scriptblock(param($Entrada, $Sessao)).
        Ao final, sem falhas, marca a sessão com revertido.txt.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Manipuladores', Justification = 'Usado no scriptblock passado a Invoke-ItemOtimizacao.')]
    param(
        [Parameter(Mandatory)]$Sessao,
        [Parameter(Mandatory)]$Alvo,
        [hashtable]$Manipuladores = @{}
    )
    $entradas = @($Alvo.Entradas)
    [array]::Reverse($entradas)
    $falhasAntes = @($Sessao.Linhas | Where-Object Resultado -eq 'Falha').Count

    foreach ($e in $entradas) {
        Invoke-ItemOtimizacao -Sessao $Sessao -Id $e.Item -Acao {
            if ($e.Tipo -eq 'Registro') {
                if ($e.Escopo -eq 'Usuario') {
                    $u = Get-UsuarioAlvo -Sid $e.Sid
                    Invoke-NoHiveUsuario -Sid $u.Sid -Perfil $u.Perfil -ScriptBlock { param($r) Restore-ValorRegistro -Sessao $Sessao -Entrada $e -Raiz $r } | Out-Null
                }
                else {
                    $raizMaquina = if ($e.PSObject.Properties['Raiz'] -and $e.Raiz) { $e.Raiz } else { 'Registry::HKEY_LOCAL_MACHINE' }
                    Restore-ValorRegistro -Sessao $Sessao -Entrada $e -Raiz $raizMaquina | Out-Null
                }
            }
            # A sessão vai como argumento: o manipulador não pode depender de variável da pilha de chamadas.
            elseif ($Manipuladores.ContainsKey($e.Tipo)) { & $Manipuladores[$e.Tipo] $e $Sessao | Out-Null }
            else { throw "Tipo de entrada sem reversão: $($e.Tipo)." }
        }
    }
    $falhas = @($Sessao.Linhas | Where-Object Resultado -eq 'Falha').Count - $falhasAntes
    if (-not $Sessao.Simular -and $falhas -eq 0) {
        "Revertido em $((Get-Date).ToString('s')) pela sessão $($Sessao.Pasta)" | Out-File -LiteralPath (Join-Path $Alvo.Pasta 'revertido.txt') -Encoding UTF8
    }
}

function Invoke-ReversaoPendente {
    <#
    .SYNOPSIS
        Reverte a sessão indicada em Pasta ou, sem Pasta, todas as sessões de aplicação do script ainda não revertidas,
        da mais recente para a mais antiga (volta ao estado anterior à primeira delas). Para na primeira sessão com falha.
    .DESCRIPTION
        A sessão da própria reversão deve ser criada com Script '<Script>-Reversao', para não casar com '*-<Script>'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Sessao,
        [Parameter(Mandatory)][string]$Cliente,
        [Parameter(Mandatory)][string]$Script,
        [string]$Pasta,
        [hashtable]$Manipuladores = @{},
        [string]$Raiz = $script:RaizBackup
    )
    # Blocos { $_.FullName } em vez de "ForEach-Object FullName": a forma por nome de membro respeita -WhatIf.
    # @() em volta do if: a atribuição desenrola o resultado (vazio vira $null, um item vira string) e o StrictMode recusa .Count.
    $pastas = @(if ($Pasta) { $Pasta } else {
            Get-ChildItem -LiteralPath (Join-Path $Raiz $Cliente) -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like "*-$Script" -and -not (Test-Path -LiteralPath (Join-Path $_.FullName 'revertido.txt')) } |
                Sort-Object -Property Name -Descending | ForEach-Object { $_.FullName }
        })
    if (-not $pastas.Count) { throw "Nenhuma sessão de $Script não revertida encontrada para o cliente $Cliente." }
    foreach ($p in $pastas) {
        $alvo = Get-SessaoParaReverter -Cliente $Cliente -Script $Script -Pasta $p -Raiz $Raiz
        Write-LogOtimizacao -Sessao $Sessao -Item 'Reversao' -Alvo $alvo.Pasta -Resultado Info -Detalhe "$(@($alvo.Entradas).Count) entrada(s)" | Out-Null
        $falhasAntes = @($Sessao.Linhas | Where-Object Resultado -eq 'Falha').Count
        Invoke-Reversao -Sessao $Sessao -Alvo $alvo -Manipuladores $Manipuladores
        if (@($Sessao.Linhas | Where-Object Resultado -eq 'Falha').Count -gt $falhasAntes) {
            Write-LogOtimizacao -Sessao $Sessao -Item 'Reversao' -Alvo $alvo.Pasta -Resultado Falha -Detalhe 'Reversão interrompida: sessões mais antigas não foram revertidas. Corrija e execute -Revert de novo.' | Out-Null
            break
        }
    }
}

#endregion

#region Programas instalados (somente leitura)

if (-not ('Otimizacao.Recurso' -as [type])) {
    Add-Type -Namespace Otimizacao -Name Recurso -MemberDefinition @'
[DllImport("shlwapi.dll", CharSet = CharSet.Unicode)] public static extern int SHLoadIndirectString(string origem, System.Text.StringBuilder destino, int tamanho, System.IntPtr reservado);
'@
}

function Resolve-TextoPacote {
    <#
    .SYNOPSIS
        Texto do manifesto de um pacote Appx. "ms-resource:" é resolvido no idioma do Windows por SHLoadIndirectString
        com "@{PackageFullName?ms-resource://...}" (learn.microsoft.com/windows/win32/api/shlwapi/nf-shlwapi-shloadindirectstring).
        As duas formas de URI cobrem os manifestos medidos na VM 26300 (ex.: "AppName", "Clipchamp/AppName", "LensSDK/Resources/AppStoreName").
        Sem resolução, devolve $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Texto, [Parameter(Mandatory)][string]$Nome, [Parameter(Mandatory)][string]$NomeCompleto)
    if (-not $Texto) { return $null }
    if ($Texto -notlike 'ms-resource:*') { return $Texto }
    $resto = $Texto.Substring(12)
    $uris = @(if ($resto -like '//*') { $Texto } elseif ($resto -like '/*') { "ms-resource://$Nome$resto" } else { "ms-resource://$Nome/resources/$resto"; "ms-resource://$Nome/$resto" })
    foreach ($u in $uris) {
        $sb = New-Object Text.StringBuilder 1024
        if ([Otimizacao.Recurso]::SHLoadIndirectString(('@{' + $NomeCompleto + '?' + $u + '}'), $sb, $sb.Capacity, [IntPtr]::Zero) -eq 0 -and $sb.Length) { return $sb.ToString() }
    }
    $null
}

function Get-NomeExibicaoAppx {
    <#
    .SYNOPSIS
        Nome de exibição e fabricante de um pacote Appx lidos do AppxManifest.xml (Properties). Sem manifesto legível, usa o nome do pacote.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Pacote)
    $nome = $null; $fabricante = $null
    try {
        $x = New-Object Xml.XmlDocument
        $x.Load((Join-Path $Pacote.InstallLocation 'AppxManifest.xml'))
        $prop = $x.DocumentElement['Properties']
        if ($prop) {
            $id = @{ Nome = [string]$Pacote.Name; NomeCompleto = [string]$Pacote.PackageFullName }
            if ($prop['DisplayName']) { $nome = Resolve-TextoPacote -Texto $prop['DisplayName'].InnerText @id }
            if ($prop['PublisherDisplayName']) { $fabricante = Resolve-TextoPacote -Texto $prop['PublisherDisplayName'].InnerText @id }
        }
    }
    catch { Write-Verbose "Manifesto de $($Pacote.Name) não lido: $($_.Exception.Message)" }
    [pscustomobject]@{ Nome = if ($nome) { $nome } else { [string]$Pacote.Name }; Fabricante = $fabricante }
}

function ConvertFrom-EntradaUninstall {
    <#
    .SYNOPSIS
        Converte os valores de uma subchave de ...\CurrentVersion\Uninstall num programa, ou nada se a entrada não
        aparece em Programas e Recursos: sem DisplayName, SystemComponent = 1, atualização (ParentKeyName ou ReleaseType).
        WindowsInstaller = 1 com chave no formato {GUID} = MSI (a chave é o ProductCode); o resto é EXE.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Valores', Justification = 'Usado no scriptblock de leitura.')]
    param([Parameter(Mandatory)][string]$Chave, [Parameter(Mandatory)][hashtable]$Valores, [Parameter(Mandatory)][string]$Escopo)
    $v = { param($n) if ($Valores.ContainsKey($n)) { $Valores[$n] } else { $null } }
    $nome = [string](& $v 'DisplayName')
    if (-not $nome.Trim()) { return }
    if ([string](& $v 'SystemComponent') -eq '1' -or (& $v 'ParentKeyName') -or [string](& $v 'ReleaseType') -match 'Update|Hotfix') { return }
    $msi = [string](& $v 'WindowsInstaller') -eq '1' -and $Chave -match '^\{[0-9A-Fa-f-]{36}\}$'
    $kb = & $v 'EstimatedSize'
    [pscustomobject]@{
        Nome         = $nome.Trim()
        Fabricante   = [string](& $v 'Publisher')
        Versao       = [string](& $v 'DisplayVersion')
        TamanhoMB    = if ($null -ne $kb -and [string]$kb -match '^\d+$') { [math]::Round([double]$kb / 1024, 1) } else { $null }
        Tipo         = if ($msi) { 'MSI' } else { 'EXE' }
        Id           = $Chave
        Escopo       = $Escopo
        Desinstalar  = [string](& $v 'UninstallString')
    }
}

function Get-ProgramaRegistro {
    <#
    .SYNOPSIS
        Programas de uma chave Uninstall (ex.: Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Caminho, [Parameter(Mandatory)][string]$Escopo)
    foreach ($k in @(Get-ChildItem -LiteralPath $Caminho -ErrorAction SilentlyContinue)) {
        $valores = @{}
        foreach ($n in $k.GetValueNames()) { if ($n) { $valores[$n] = $k.GetValue($n) } }
        ConvertFrom-EntradaUninstall -Chave $k.PSChildName -Valores $valores -Escopo $Escopo
    }
}

#endregion

Export-ModuleMember -Function Test-Administrador, Get-InfoWindows, Test-ReinicializacaoPendente, Get-TipoEquipamento, Test-GerenciadoMdm, Get-UsuarioAlvo, Invoke-NoHiveUsuario,
    Resolve-TextoPacote, Get-NomeExibicaoAppx, ConvertFrom-EntradaUninstall, Get-ProgramaRegistro,
    Import-PerfilCliente, Get-ItemPerfil, Test-Protegido, Test-PreCondicao, New-PontoRestauracao,
    New-SessaoOtimizacao, Write-LogOtimizacao, Add-EstadoOriginal, Invoke-ItemOtimizacao, Get-ResumoSessao,
    Get-ValorRegistro, Test-ValorIgual, Set-ValorRegistro, Restore-ValorRegistro, Get-SessaoParaReverter, Invoke-Reversao, Invoke-ReversaoPendente
