<#
.SYNOPSIS
    Coleta somente leitura do estado técnico do PC e comparação antes/depois.

.DESCRIPTION
    Modo Coletar (padrão): gera um JSON local com sistema e status de suporte, hardware, discos e saúde,
    BitLocker, desempenho em repouso (amostragem), processos, inicialização, tarefas agendadas de terceiros,
    serviços, energia, efeitos visuais do usuário alvo, temporários e caches, atualizações pendentes,
    tempo de boot, antivírus, dispositivos com erro no Gerenciador de Dispositivos (M5), eventos de disco,
    sistema de arquivos e hardware dos últimos 30 dias por disco físico (M6) e, em notebook, relatório de bateria
    (M7: powercfg /batteryreport, HTML na pasta de saída para mostrar ao cliente) e programas instalados (registro Uninstall
    da máquina e do usuário alvo, e apps Appx que não são do sistema), base da lista do A2 (Aplicativos).
    Modo Comparar: lê as coletas antes e a coleta depois e gera um HTML com as métricas, a faixa de ruído medida
    e as condições de cada coleta.

    Não altera o sistema. Única exceção: se o usuário alvo não estiver conectado, o NTUSER.DAT dele é carregado
    somente para leitura e descarregado ao final.
    LGPD: coleta apenas dados técnicos. Não lê conteúdo de arquivos, senhas, chaves de licença nem histórico
    de navegação. Nada é enviado; o relatório fica na pasta de saída. O relatório de bateria do Windows inclui
    horários de uso do último dia (ligado, suspenso): mostrar ao cliente e não repassar a terceiros.

    Recomendado executar como administrador: sem elevação, saúde dos discos, BitLocker, bateria e eventos de
    boot ficam indisponíveis (registrado em Erros no JSON).

    Método para comparar antes e depois, sempre com o mesmo -AguardarUptimeMinutos e -AmostraSegundos e na mesma
    fonte de energia: reiniciar e coletar (antes 1); reiniciar e coletar (antes 2); otimizar; reiniciar e coletar (depois).

.PARAMETER UsuarioSid
    SID do usuário cujo HKCU e pasta de inicialização serão lidos. Padrão: usuário conectado ao console.

.PARAMETER AmostraSegundos
    Duração da amostragem de desempenho em repouso (CPU, memória, disco, CPU por processo). Padrão: 300.

.PARAMETER AguardarUptimeMinutos
    Aguarda o sistema atingir este tempo desde o boot antes de amostrar. Padrão: 0 (não aguarda).

.PARAMETER PastaSaida
    Pasta do JSON. Padrão: subpasta relatorios ao lado do script.

.PARAMETER Comparar
    Ativa o modo de comparação. Exige -Antes e -Depois.

.PARAMETER Antes
    Um ou mais JSON de coletas anteriores à otimização. Com dois ou mais (reinicialização entre eles), a variação
    entre eles define a faixa de ruído e diferenças dentro dela não são atribuídas à otimização.

.PARAMETER Depois
    JSON da coleta posterior à otimização.

.PARAMETER SaidaHtml
    Caminho do HTML de comparação. Padrão: mesma pasta do JSON -Depois.

.EXAMPLE
    .\Coleta.ps1 -AguardarUptimeMinutos 10

.EXAMPLE
    .\Coleta.ps1 -Comparar -Antes .\relatorios\PC01_antes1.json, .\relatorios\PC01_antes2.json -Depois .\relatorios\PC01_depois.json

.NOTES
    O que altera: nada. O que se perde: nada. Reversão: não se aplica.
    Requer Windows PowerShell 5.1, Windows 10 ou 11. Não depende do idioma do Windows.
#>
[CmdletBinding(DefaultParameterSetName = 'Coletar')]
param(
    [Parameter(ParameterSetName = 'Coletar')]
    [string]$UsuarioSid,

    [Parameter(ParameterSetName = 'Coletar')]
    [ValidateRange(10, 900)]
    [int]$AmostraSegundos = 300,

    [Parameter(ParameterSetName = 'Coletar')]
    [ValidateRange(0, 120)]
    [int]$AguardarUptimeMinutos = 0,

    [Parameter(ParameterSetName = 'Coletar')]
    [string]$PastaSaida,

    [Parameter(ParameterSetName = 'Comparar', Mandatory)]
    [switch]$Comparar,

    [Parameter(ParameterSetName = 'Comparar', Mandatory)]
    [string[]]$Antes,

    [Parameter(ParameterSetName = 'Comparar', Mandatory)]
    [string]$Depois,

    [Parameter(ParameterSetName = 'Comparar')]
    [string]$SaidaHtml
)

Import-Module (Join-Path $PSScriptRoot 'Otimizacao.Comum.psm1') -Force

$script:VersaoColeta = '1.3.0'
$script:IntervaloAmostra = 5
$script:DiasEventos = 30

if (-not ('Otimizacao.Volume' -as [type])) {
    Add-Type -Namespace Otimizacao -Name Volume -MemberDefinition @'
[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern uint QueryDosDevice(string nome, System.Text.StringBuilder destino, int tamanho);
'@
}

# Códigos do Gerenciador de Dispositivos (Cfg.h): learn.microsoft.com/windows-hardware/drivers/install/device-manager-error-messages
$script:ProblemasPnp = @{
    1 = 'CM_PROB_NOT_CONFIGURED'; 3 = 'CM_PROB_OUT_OF_MEMORY'; 9 = 'CM_PROB_INVALID_DATA'; 10 = 'CM_PROB_FAILED_START'
    12 = 'CM_PROB_NORMAL_CONFLICT'; 14 = 'CM_PROB_NEED_RESTART'; 16 = 'CM_PROB_PARTIAL_LOG_CONF'; 18 = 'CM_PROB_REINSTALL'
    19 = 'CM_PROB_REGISTRY'; 21 = 'CM_PROB_WILL_BE_REMOVED'; 22 = 'CM_PROB_DISABLED'; 24 = 'CM_PROB_DEVICE_NOT_THERE'
    28 = 'CM_PROB_FAILED_INSTALL'; 29 = 'CM_PROB_HARDWARE_DISABLED'; 31 = 'CM_PROB_FAILED_ADD'; 32 = 'CM_PROB_DISABLED_SERVICE'
    33 = 'CM_PROB_TRANSLATION_FAILED'; 34 = 'CM_PROB_NO_SOFTCONFIG'; 35 = 'CM_PROB_BIOS_TABLE'; 36 = 'CM_PROB_IRQ_TRANSLATION_FAILED'
    37 = 'CM_PROB_FAILED_DRIVER_ENTRY'; 38 = 'CM_PROB_DRIVER_FAILED_PRIOR_UNLOAD'; 39 = 'CM_PROB_DRIVER_FAILED_LOAD'
    40 = 'CM_PROB_DRIVER_SERVICE_KEY_INVALID'; 41 = 'CM_PROB_LEGACY_SERVICE_NO_DEVICES'; 42 = 'CM_PROB_DUPLICATE_DEVICE'
    43 = 'CM_PROB_FAILED_POST_START'; 44 = 'CM_PROB_HALTED'; 45 = 'CM_PROB_PHANTOM'; 46 = 'CM_PROB_SYSTEM_SHUTDOWN'
    47 = 'CM_PROB_HELD_FOR_EJECT'; 48 = 'CM_PROB_DRIVER_BLOCKED'; 49 = 'CM_PROB_REGISTRY_TOO_LARGE'; 50 = 'CM_PROB_SETPROPERTIES_FAILED'
    51 = 'CM_PROB_WAITING_ON_DEPENDENCY'; 52 = 'CM_PROB_UNSIGNED_DRIVER'; 53 = 'CM_PROB_USED_BY_DEBUGGER'; 54 = 'CM_PROB_DEVICE_RESET'
    55 = 'CM_PROB_CONSOLE_LOCKED'; 56 = 'CM_PROB_NEED_CLASS_CONFIG'; 57 = 'CM_PROB_GUEST_ASSIGNMENT_FAILED'
}

#region Funções auxiliares

function ConvertTo-DataIso {
    param($Data)
    if ($Data -is [datetime]) { $Data.ToString('s') } else { $Data }
}

function Get-StatusSuporte {
    <#
        Fim das atualizações por build e edição. Fonte: learn.microsoft.com/windows/release-health
        (windows11-release-information e release-information), consultado em 2026-10-08.
    #>
    param(
        [Parameter(Mandatory)][int]$Build,
        [Parameter(Mandatory)][string]$EditionId,
        [datetime]$Data = (Get-Date)
    )
    $ltsc = $EditionId -match '^(Enterprise|IoTEnterprise)S'
    $corporativo = $EditionId -match '^(Enterprise|Education|IoTEnterprise|ServerRdsh)'
    $fim = $null
    $obs = $null

    if ($ltsc) {
        $tabela = @{ 26100 = '2034-10-10'; 19044 = '2027-01-12'; 17763 = '2029-01-09'; 14393 = '2026-10-13' }
        if ($EditionId -like 'IoTEnterpriseS*' -and $Build -eq 19044) { $fim = '2032-01-13' }
        elseif ($tabela.ContainsKey($Build)) { $fim = $tabela[$Build] }
    }
    else {
        # Build = @(Home/Pro, Enterprise/Education)
        $tabela = @{
            28000 = @('2028-03-14', '2029-03-13')
            26300 = @('2028-10-10', '2029-10-09')
            26200 = @('2027-10-12', '2028-10-10')
            26100 = @('2026-10-13', '2027-10-12')
            22631 = @('2025-11-11', '2026-11-10')
            22621 = @('2024-10-08', '2025-10-14')
            22000 = @('2023-10-10', '2024-10-08')
            19045 = @('2025-10-14', '2025-10-14')
        }
        if ($tabela.ContainsKey($Build)) { $fim = $tabela[$Build][[int]$corporativo] }
        elseif ($Build -lt 19045) { $obs = 'Versão anterior ao Windows 10 22H2: sem suporte.' }
        if ($Build -eq 19045) { $obs = 'Windows 10 encerrado em 2025-10-14. Atualizações de segurança apenas com inscrição no ESU.' }
    }

    if (-not $fim) {
        if (-not $obs) { $obs = 'Build fora da tabela: consultar learn.microsoft.com/windows/release-health.' }
        return [pscustomobject]@{ FimSuporte = $null; Suportado = if ($Build -lt 19045 -and -not $ltsc) { $false } else { $null }; DiasRestantes = $null; Observacao = $obs }
    }
    $dataFim = [datetime]::ParseExact($fim, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    [pscustomobject]@{
        FimSuporte    = $fim
        Suportado     = $Data.Date -le $dataFim
        DiasRestantes = [int]($dataFim - $Data.Date).TotalDays
        Observacao    = $obs
    }
}

function Get-TamanhoPasta {
    <# Soma tamanho e quantidade de arquivos. Aceita curingas no caminho (ex.: User Data\*\Cache). #>
    param([string[]]$Caminho)
    $bytes = 0L
    $arquivos = 0
    foreach ($c in $Caminho) {
        foreach ($pasta in @(Get-Item -Path $c -Force -ErrorAction SilentlyContinue)) {
            Get-ChildItem -LiteralPath $pasta.FullName -Recurse -Force -File -ErrorAction SilentlyContinue |
                ForEach-Object { $bytes += $_.Length; $arquivos++ }
        }
    }
    [pscustomobject]@{ MB = [math]::Round($bytes / 1MB, 1); Arquivos = $arquivos }
}

function Get-EstadoStartupApproved {
    <# Primeiro byte do valor em ...\Explorer\StartupApproved: bit 0 ligado = desabilitado pelo usuário. Ausente = habilitado. #>
    param([byte[]]$Valor)
    if (-not $Valor -or $Valor.Length -eq 0) { return 'Habilitado' }
    if ($Valor[0] -band 1) { 'Desabilitado' } else { 'Habilitado' }
}

function Get-EntradaRun {
    param([string]$ChaveRun, [string]$ChaveAprovacao, [string]$Origem)
    $run = Get-Item -LiteralPath $ChaveRun -ErrorAction SilentlyContinue
    if (-not $run) { return }
    $aprov = Get-Item -LiteralPath $ChaveAprovacao -ErrorAction SilentlyContinue
    foreach ($nome in $run.GetValueNames()) {
        if (-not $nome) { continue }
        $valor = if ($aprov) { $aprov.GetValue($nome) } else { $null }
        [pscustomobject]@{ Origem = $Origem; Nome = $nome; Comando = [string]$run.GetValue($nome); Estado = Get-EstadoStartupApproved $valor }
    }
}

function Get-EntradaPastaStartup {
    param([string]$Pasta, [string]$ChaveAprovacao, [string]$Origem)
    if (-not $Pasta -or -not (Test-Path -LiteralPath $Pasta)) { return }
    $aprov = Get-Item -LiteralPath $ChaveAprovacao -ErrorAction SilentlyContinue
    foreach ($arq in Get-ChildItem -LiteralPath $Pasta -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' }) {
        $valor = if ($aprov) { $aprov.GetValue($arq.Name) } else { $null }
        [pscustomobject]@{ Origem = $Origem; Nome = $arq.Name; Comando = $arq.FullName; Estado = Get-EstadoStartupApproved $valor }
    }
}

function Get-ExecutavelServico {
    <# Extrai o caminho do executável de Win32_Service.PathName. #>
    param([string]$PathName)
    if (-not $PathName) { return $null }
    $p = [Environment]::ExpandEnvironmentVariables($PathName.Trim())
    if ($p.StartsWith('"')) { return $p.Substring(1, $p.IndexOf('"', 1) - 1) }
    $i = $p.IndexOf('.exe', [StringComparison]::OrdinalIgnoreCase)
    if ($i -ge 0) { return $p.Substring(0, $i + 4) }
    ($p -split ' ')[0]
}

function Get-NomePlanoEnergia {
    <# GUIDs dos planos padrão: learn.microsoft.com/windows-hardware/customize/power-settings #>
    param([string]$Guid)
    switch ($Guid) {
        '381b4222-f694-41f0-9685-ff5bb260df2e' { 'Equilibrado' }
        '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' { 'Alto desempenho' }
        'a1841308-3541-4fab-bc81-f71556f20b4a' { 'Economia de energia' }
        'e9a42b02-d5df-448d-aa00-03f14749eb61' { 'Desempenho máximo' }
        default { 'Personalizado ou do fabricante' }
    }
}

function Invoke-Secao {
    param([string]$Nome, [scriptblock]$Bloco)
    Write-Verbose "Coletando: $Nome"
    try { & $Bloco }
    catch {
        $script:Erros.Add([pscustomobject]@{ Secao = $Nome; Erro = $_.Exception.Message })
        $null
    }
}

#endregion

#region Seções da coleta

function Get-SecaoSistema {
    $w = Get-InfoWindows
    $cs = Get-CimInstance Win32_ComputerSystem
    $mdm = try { Test-GerenciadoMdm } catch { $null }
    [pscustomobject]@{
        Produto               = $w.Produto
        Familia               = $w.Familia
        EditionId             = $w.EditionId
        DisplayVersion        = $w.DisplayVersion
        Build                 = $w.Build
        UBR                   = $w.UBR
        Arquitetura           = $w.Arquitetura
        IdiomaSO              = $w.IdiomaSO
        Instalado             = ConvertTo-DataIso $w.Instalado
        UltimoBoot            = ConvertTo-DataIso $w.UltimoBoot
        UptimeMinutos         = [int]((Get-Date) - $w.UltimoBoot).TotalMinutes
        Suporte               = Get-StatusSuporte -Build $w.Build -EditionId $w.EditionId
        EmDominio             = [bool]$cs.PartOfDomain
        Dominio               = if ($cs.PartOfDomain) { $cs.Domain } else { $null }
        GerenciadoMDM         = $mdm
        ReinicializacaoPendente = Test-ReinicializacaoPendente
    }
}

function Get-SecaoHardware {
    $cs = Get-CimInstance Win32_ComputerSystem
    $cpu = @(Get-CimInstance Win32_Processor)
    $bios = Get-CimInstance Win32_BIOS
    $slots = (@(Get-CimInstance Win32_PhysicalMemoryArray) | Measure-Object -Property MemoryDevices -Sum).Sum
    [pscustomobject]@{
        Fabricante   = $cs.Manufacturer
        Modelo       = $cs.Model
        Tipo         = Get-TipoEquipamento
        Processador  = $cpu[0].Name.Trim()
        Nucleos      = ($cpu | Measure-Object -Property NumberOfCores -Sum).Sum
        Logicos      = ($cpu | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
        RamGB        = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        SlotsRam     = $slots
        PentesRam    = @(Get-CimInstance Win32_PhysicalMemory | ForEach-Object {
                [pscustomobject]@{ GB = [math]::Round($_.Capacity / 1GB, 1); MHz = $_.ConfiguredClockSpeed; Fabricante = $_.Manufacturer } })
        BiosVersao   = $bios.SMBIOSBIOSVersion
        BiosData     = ConvertTo-DataIso $bios.ReleaseDate
    }
}

function Get-SecaoDisco {
    $fisicos = foreach ($d in Get-PhysicalDisk) {
        $conf = $null
        try {
            $r = $d | Get-StorageReliabilityCounter -ErrorAction Stop
            $conf = [pscustomobject]@{
                TemperaturaC = $r.Temperature; TemperaturaMaxC = $r.TemperatureMax; DesgastePct = $r.Wear
                HorasLigado = $r.PowerOnHours; ErrosLeituraNaoCorrigidos = $r.ReadErrorsUncorrected
                ErrosEscritaNaoCorrigidos = $r.WriteErrorsUncorrected
            }
        }
        catch { $script:Erros.Add([pscustomobject]@{ Secao = "Confiabilidade disco $($d.DeviceId)"; Erro = $_.Exception.Message }) }
        [pscustomobject]@{
            Id = $d.DeviceId; Modelo = $d.FriendlyName; Midia = [string]$d.MediaType; Barramento = [string]$d.BusType
            TamanhoGB = [math]::Round($d.Size / 1GB); Saude = [string]$d.HealthStatus
            Operacional = (@($d.OperationalStatus) | ForEach-Object { [string]$_ }) -join ','
            Confiabilidade = $conf
        }
    }
    $volumes = Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' } | ForEach-Object {
        [pscustomobject]@{
            Letra = [string]$_.DriveLetter; Sistema = $_.FileSystem; TamanhoGB = [math]::Round($_.Size / 1GB, 1)
            LivreGB = [math]::Round($_.SizeRemaining / 1GB, 1)
            LivrePct = if ($_.Size) { [math]::Round(100 * $_.SizeRemaining / $_.Size, 1) } else { $null }
            Saude = [string]$_.HealthStatus
        }
    }
    [pscustomobject]@{ Fisicos = @($fisicos); Volumes = @($volumes) }
}

function Get-SecaoBitLocker {
    # ProtectionStatus: 0 desligada, 1 ligada, 2 desconhecida
    Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -ErrorAction Stop |
        ForEach-Object { [pscustomobject]@{ Letra = $_.DriveLetter; Protecao = $_.ProtectionStatus } }
}

function Get-AmostraDesempenho {
    $cpu = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'"
    $mem = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
    $dsk = Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk -Filter "Name='_Total'"
    [pscustomobject]@{
        CpuPct          = [double]$cpu.PercentProcessorTime
        MemDisponivelMB = [double]$mem.AvailableMBytes
        CommitPct       = [double]$mem.PercentCommittedBytesInUse
        PaginasSeg      = [double]$mem.PagesPerSec
        DiscoOciosoPct  = [double]$dsk.PercentIdleTime
        FilaDisco       = [double]$dsk.AvgDiskQueueLength
    }
}

function Get-TempoCpuProcesso {
    $t = @{}
    foreach ($p in Get-Process) {
        try { $t[$p.Id] = $p.TotalProcessorTime.TotalSeconds } catch { Write-Debug "Sem acesso ao processo $($p.Id)" }
    }
    $t
}

function Get-SecaoDesempenho {
    param([int]$Segundos)
    $logicos = [Environment]::ProcessorCount
    $t0 = Get-TempoCpuProcesso
    $relogio = [Diagnostics.Stopwatch]::StartNew()
    $amostras = New-Object System.Collections.Generic.List[object]
    while ($relogio.Elapsed.TotalSeconds -lt $Segundos) {
        Write-Progress -Activity 'Amostrando desempenho em repouso' -PercentComplete ([math]::Min(100, 100 * $relogio.Elapsed.TotalSeconds / $Segundos))
        $amostras.Add((Get-AmostraDesempenho))
        Start-Sleep -Seconds $script:IntervaloAmostra
    }
    Write-Progress -Activity 'Amostrando desempenho em repouso' -Completed
    $decorrido = $relogio.Elapsed.TotalSeconds
    $t1 = Get-TempoCpuProcesso

    $resumo = [ordered]@{ Amostras = $amostras.Count; Segundos = [int]$decorrido }
    foreach ($campo in 'CpuPct', 'MemDisponivelMB', 'CommitPct', 'PaginasSeg', 'DiscoOciosoPct', 'FilaDisco') {
        $m = $amostras | Measure-Object -Property $campo -Average -Maximum -Minimum
        $resumo[$campo] = [pscustomobject]@{ Media = [math]::Round($m.Average, 1); Min = $m.Minimum; Max = $m.Maximum }
    }

    $processos = Get-Process | Group-Object -Property ProcessName | ForEach-Object {
        $cpuSeg = 0.0
        foreach ($p in $_.Group) {
            if ($t0.ContainsKey($p.Id) -and $t1.ContainsKey($p.Id)) { $cpuSeg += $t1[$p.Id] - $t0[$p.Id] }
        }
        [pscustomobject]@{
            Nome       = $_.Name
            Instancias = $_.Count
            MemoriaMB  = [math]::Round(($_.Group | Measure-Object -Property WorkingSet64 -Sum).Sum / 1MB)
            PrivadaMB  = [math]::Round(($_.Group | Measure-Object -Property PrivateMemorySize64 -Sum).Sum / 1MB)
            CpuPct     = [math]::Round(100 * $cpuSeg / ($decorrido * $logicos), 2)
        }
    } | Sort-Object -Property MemoriaMB -Descending

    [pscustomobject]@{
        Resumo         = [pscustomobject]$resumo
        TotalProcessos = @(Get-Process).Count
        Processos      = @($processos)
    }
}

function Get-SecaoUsuario {
    <# Itens que dependem do hive do usuário alvo: inicialização do usuário e efeitos visuais. #>
    param($Alvo)
    Invoke-NoHiveUsuario -Sid $Alvo.Sid -Perfil $Alvo.Perfil -ScriptBlock {
        param($raiz)
        $sw = "$raiz\Software\Microsoft\Windows\CurrentVersion"
        $pastaStartup = $null
        $usf = Get-Item -LiteralPath "$sw\Explorer\User Shell Folders" -ErrorAction SilentlyContinue
        if ($usf) {
            $bruto = $usf.GetValue('Startup', $null, 'DoNotExpandEnvironmentNames')
            if ($bruto) { $pastaStartup = $bruto -replace '%USERPROFILE%', $Alvo.Perfil }
        }
        $ve = Get-ItemProperty -LiteralPath "$sw\Explorer\VisualEffects" -ErrorAction SilentlyContinue
        $programas = @(Get-ProgramaRegistro -Caminho "$sw\Uninstall" -Escopo 'Usuario')
        $pe = Get-ItemProperty -LiteralPath "$sw\Themes\Personalize" -ErrorAction SilentlyContinue
        [pscustomobject]@{
            Inicializacao = @(
                Get-EntradaRun -ChaveRun "$sw\Run" -ChaveAprovacao "$sw\Explorer\StartupApproved\Run" -Origem 'Usuario\Run'
                Get-EntradaPastaStartup -Pasta $pastaStartup -ChaveAprovacao "$sw\Explorer\StartupApproved\StartupFolder" -Origem 'Usuario\PastaInicializar'
            )
            Visual = [pscustomobject]@{
                # 0 Windows decide, 1 aparência, 2 desempenho, 3 personalizado; ausente = padrão
                VisualFXSetting   = if ($ve -and $ve.PSObject.Properties['VisualFXSetting']) { $ve.VisualFXSetting } else { $null }
                EnableTransparency = if ($pe -and $pe.PSObject.Properties['EnableTransparency']) { $pe.EnableTransparency } else { $null }
            }
            Programas = $programas
        }
    }
}

function Get-SecaoInicializacaoMaquina {
    $base = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion'
    @(
        Get-EntradaRun -ChaveRun "$base\Run" -ChaveAprovacao "$base\Explorer\StartupApproved\Run" -Origem 'Maquina\Run'
        Get-EntradaRun -ChaveRun 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run' -ChaveAprovacao "$base\Explorer\StartupApproved\Run32" -Origem 'Maquina\Run32'
        Get-EntradaPastaStartup -Pasta ([Environment]::GetFolderPath('CommonStartup')) -ChaveAprovacao "$base\Explorer\StartupApproved\StartupFolder" -Origem 'Maquina\PastaInicializar'
    )
}

function Get-SecaoTarefa {
    Get-ScheduledTask | Where-Object { $_.TaskPath -notlike '\Microsoft\*' } | ForEach-Object {
        [pscustomobject]@{
            Caminho  = $_.TaskPath + $_.TaskName
            Estado   = [string]$_.State
            Gatilhos = (@($_.Triggers) | Where-Object { $_ } | ForEach-Object { $_.CimClass.CimClassName -replace '^MSFT_Task|Trigger$', '' }) -join ','
            Acao     = (@($_.Actions) | Where-Object { $_.PSObject.Properties['Execute'] } | ForEach-Object { $_.Execute }) -join ' | '
        }
    }
}

function Get-SecaoServico {
    $empresas = @{}
    Get-CimInstance Win32_Service | ForEach-Object {
        $exe = Get-ExecutavelServico $_.PathName
        if ($exe -and -not $empresas.ContainsKey($exe)) {
            $empresas[$exe] = if (Test-Path -LiteralPath $exe) { (Get-Item -LiteralPath $exe).VersionInfo.CompanyName } else { $null }
        }
        [pscustomobject]@{
            Nome       = $_.Name
            Exibicao   = $_.DisplayName
            Inicio     = $_.StartMode
            Atrasado   = [bool]$_.DelayedAutoStart
            Estado     = $_.State
            Empresa    = if ($exe) { $empresas[$exe] } else { $null }
        }
    }
}

function Get-SecaoEnergia {
    $guid = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes').ActivePowerScheme
    $pw = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction SilentlyContinue
    $baterias = @(Get-CimInstance Win32_Battery)
    $saude = $null
    if ($baterias.Count) {
        try {
            $proj = (Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction Stop | Select-Object -First 1).DesignedCapacity
            $atual = (Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction Stop | Select-Object -First 1).FullChargedCapacity
            if ($proj) { $saude = [math]::Round(100 * $atual / $proj, 1) }
        }
        catch { $script:Erros.Add([pscustomobject]@{ Secao = 'Saúde da bateria'; Erro = $_.Exception.Message }) }
    }
    [pscustomobject]@{
        PlanoGuid        = $guid
        PlanoNome        = Get-NomePlanoEnergia $guid
        InicializacaoRapida = if ($pw -and $pw.PSObject.Properties['HiberbootEnabled']) { $pw.HiberbootEnabled } else { $null }
        TemBateria       = [bool]$baterias.Count
        # Win32_Battery.BatteryStatus 2 = com acesso à rede elétrica
        NaBateria        = [bool]($baterias.Count -and @($baterias | Where-Object { $_.BatteryStatus -ne 2 }).Count)
        CargaPct         = if ($baterias.Count) { $baterias[0].EstimatedChargeRemaining } else { $null }
        SaudeBateriaPct  = $saude
    }
}

function Get-SecaoArmazenamento {
    $perfis = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' |
        Where-Object { $_.PSChildName -like 'S-1-5-21-*' } |
        ForEach-Object { $_.GetValue('ProfileImagePath') } | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    $local = @($perfis | ForEach-Object { Join-Path $_ 'AppData\Local' })

    $itens = [ordered]@{
        TempWindows       = Get-TamanhoPasta (Join-Path $env:windir 'Temp')
        TempUsuarios      = Get-TamanhoPasta ($local | ForEach-Object { Join-Path $_ 'Temp' })
        CacheChrome       = Get-TamanhoPasta ($local | ForEach-Object { Join-Path $_ 'Google\Chrome\User Data\*\Cache' })
        CacheEdge         = Get-TamanhoPasta ($local | ForEach-Object { Join-Path $_ 'Microsoft\Edge\User Data\*\Cache' })
        DownloadsWindowsUpdate = Get-TamanhoPasta (Join-Path $env:windir 'SoftwareDistribution\Download')
        WindowsOld        = Get-TamanhoPasta (Join-Path $env:SystemDrive 'Windows.old')
        Lixeira           = Get-TamanhoPasta (Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' } | ForEach-Object { "$($_.DriveLetter):\`$Recycle.Bin" })
    }
    [pscustomobject]@{
        Perfis  = @($perfis).Count
        Itens   = [pscustomobject]$itens
        TotalMB = [math]::Round(($itens.Values | Measure-Object -Property MB -Sum).Sum, 1)
    }
}

function Get-SecaoAtualizacao {
    $pendentes = $null
    try {
        $buscador = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
        $buscador.Online = $false
        $r = $buscador.Search('IsInstalled=0 and IsHidden=0')
        $pendentes = @(foreach ($u in $r.Updates) { $u.Title })
    }
    catch { $script:Erros.Add([pscustomobject]@{ Secao = 'Atualizações pendentes'; Erro = $_.Exception.Message }) }
    $ultimo = Get-HotFix -ErrorAction SilentlyContinue | Where-Object { $_.InstalledOn } |
        Sort-Object -Property InstalledOn -Descending | Select-Object -First 1
    [pscustomobject]@{
        PendentesCache   = $pendentes
        UltimoHotfix     = if ($ultimo) { $ultimo.HotFixID } else { $null }
        UltimoHotfixData = if ($ultimo) { ConvertTo-DataIso $ultimo.InstalledOn } else { $null }
    }
}

function Get-SecaoBoot {
    <# Evento 100 de Microsoft-Windows-Diagnostics-Performance/Operational. Campos em milissegundos. #>
    $eventos = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 100 } -MaxEvents 5 -ErrorAction Stop
    foreach ($e in $eventos) {
        $dados = @{}
        foreach ($d in ([xml]$e.ToXml()).Event.EventData.Data) { $dados[$d.Name] = $d.'#text' }
        [pscustomobject]@{
            Data              = ConvertTo-DataIso $e.TimeCreated
            BootTime          = [int]$dados['BootTime']
            MainPathBootTime  = [int]$dados['MainPathBootTime']
            BootPostBootTime  = [int]$dados['BootPostBootTime']
        }
    }
}

function Get-SecaoPrograma {
    <#
        Programas da máquina (Uninstall 64 e 32 bits) e apps Appx que não são do sistema (SignatureKind diferente de System,
        removíveis, sem frameworks e pacotes de recurso). Tipo MSI, EXE ou Appx; Id é o ProductCode (MSI), a chave (EXE)
        ou o nome do pacote (Appx). Sem elevação, Appx só do usuário que executa e sem tamanho nem provisionamento.
    #>
    param([bool]$Elevado)
    $base = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE'
    $registro = @(
        Get-ProgramaRegistro -Caminho "$base\Microsoft\Windows\CurrentVersion\Uninstall" -Escopo 'Maquina'
        Get-ProgramaRegistro -Caminho "$base\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall" -Escopo 'Maquina32'
    )
    $pacotes = if ($Elevado) { @(Get-AppxPackage -AllUsers -ErrorAction Stop) } else { @(Get-AppxPackage -ErrorAction Stop) }
    $provisionados = if ($Elevado) { @(Get-AppxProvisionedPackage -Online -ErrorAction Stop | ForEach-Object { $_.DisplayName }) } else { $null }
    $appx = $pacotes | Where-Object { -not $_.IsFramework -and -not $_.IsResourcePackage -and -not $_.NonRemovable -and [string]$_.SignatureKind -ne 'System' } |
        Group-Object -Property Name | ForEach-Object {
            $p = $_.Group | Sort-Object -Property { [version]$_.Version } -Descending | Select-Object -First 1
            $exib = Get-NomeExibicaoAppx -Pacote $p
            [pscustomobject]@{
                Nome = $exib.Nome; Fabricante = $exib.Fabricante; Versao = [string]$p.Version
                TamanhoMB = if ($Elevado -and $p.InstallLocation) { (Get-TamanhoPasta $p.InstallLocation).MB } else { $null }
                Tipo = 'Appx'; Id = $p.Name; Escopo = 'Appx'; Desinstalar = $null
                Provisionado = if ($null -ne $provisionados) { $provisionados -contains $p.Name } else { $null }
            }
        }
    @($registro) + @($appx)
}

function Get-SecaoProtecao {
    Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop |
        ForEach-Object { [pscustomobject]@{ Nome = $_.displayName; EstadoBruto = $_.productState } }
}

function Get-SecaoDispositivo {
    <# M5. Dispositivos com problema (Win32_PnPEntity.ConfigManagerErrorCode diferente de 0). Código 22 = desabilitado, não é falha. #>
    Get-CimInstance Win32_PnPEntity -Filter 'ConfigManagerErrorCode <> 0' -ErrorAction Stop | ForEach-Object {
        $c = [int]$_.ConfigManagerErrorCode
        [pscustomobject]@{
            Nome         = $_.Name
            Classe       = $_.PNPClass
            Fabricante   = $_.Manufacturer
            Id           = $_.PNPDeviceID
            Codigo       = $c
            Problema     = if ($script:ProblemasPnp.ContainsKey($c)) { $script:ProblemasPnp[$c] } else { $null }
            Desabilitado = $c -eq 22
        }
    }
}

function Get-EventoSistema {
    <# Get-WinEvent no log Sistema. Sem eventos ou provedor não registrado: nenhuma saída. #>
    param([Parameter(Mandatory)][hashtable]$Filtro)
    $f = $Filtro.Clone()
    $f['LogName'] = 'System'
    try { Get-WinEvent -FilterHashtable $f -ErrorAction Stop }
    catch { if ($_.FullyQualifiedErrorId -notlike 'NoMatching*') { throw } }
}

function Get-NomeNtVolume {
    <# \Device\HarddiskVolumeN de um volume (Volume{guid}) por QueryDosDevice. #>
    param([string]$Volume)
    $sb = New-Object Text.StringBuilder 1024
    if ([Otimizacao.Volume]::QueryDosDevice($Volume, $sb, $sb.Capacity) -eq 0) { return $null }
    $sb.ToString()
}

function Get-MapaDisco {
    <# Número do disco físico por letra (C:), caminho \\?\Volume{guid} e nome NT (\Device\HarddiskVolumeN) dos volumes conectados. #>
    $mapa = @{}
    foreach ($p in @(Get-Partition -ErrorAction SilentlyContinue)) {
        foreach ($c in @($p.AccessPaths)) {
            if (-not $c) { continue }
            $mapa[$c.TrimEnd('\')] = [int]$p.DiskNumber
            if ($c -match '^\\\\\?\\(Volume\{[0-9A-Fa-f-]+\})\\$') {
                $nt = Get-NomeNtVolume $Matches[1]
                if ($nt) { $mapa[$nt] = [int]$p.DiskNumber }
            }
        }
    }
    $mapa
}

function Get-DispositivoEvento {
    <# Volume e dispositivo citados no evento: dados nomeados do NTFS (DriveName, VolumeId, DeviceName) ou 1º parâmetro de disk e storport. #>
    param($Evento)
    $dados = @{}
    foreach ($d in @(([xml]$Evento.ToXml()).Event.EventData.Data)) {
        if ($d -is [Xml.XmlElement] -and $d.GetAttribute('Name')) { $dados[$d.GetAttribute('Name')] = $d.InnerText }
    }
    $volume = @($dados['DriveName'], $dados['VolumeId']) | Where-Object { $_ } | Select-Object -First 1
    $disp = $dados['DeviceName']
    if (-not $disp -and @($Evento.Properties).Count) {
        $p0 = [string]$Evento.Properties[0].Value
        if ($p0 -like '\Device\*') { $disp = $p0 }
    }
    [pscustomobject]@{ Volume = $volume; Dispositivo = $disp }
}

function Resolve-DiscoEvento {
    <# Número do disco: \Device\HarddiskN\... no evento, ou volume e nome NT ainda conectados (Get-MapaDisco). #>
    param([string]$Dispositivo, [string]$Volume, [hashtable]$Mapa)
    if ($Dispositivo -match '^\\Device\\Harddisk(\d+)\\') { return [int]$Matches[1] }
    foreach ($k in @($Volume, $Dispositivo)) { if ($k -and $Mapa.ContainsKey($k)) { return $Mapa[$k] } }
    $null
}

function Get-SecaoEventoHardware {
    <#
        M6. Erros e avisos dos últimos 30 dias no log Sistema, filtrados por provedor, porque os mesmos IDs aparecem em
        provedores sem relação (medido no host: 55 do Kernel-Processor-Power, 129 do Time-Service e do Hyper-V, 153 do
        Kernel-Boot). Inclui disk, Ntfs e Microsoft-Windows-Ntfs nos níveis 1 a 3 (o 98 de nível 4 indica volume íntegro),
        ID 129 de drivers storport, WHEA-Logger (níveis 1 e 2 fatal, 3 corrigido) e Kernel-Power 41 (desligamento inesperado).
        Fontes: learn.microsoft.com/troubleshoot/windows-server/backup-and-storage/troubleshoot-data-corruption-and-disk-errors
        (55, 98, 50, 140, 129, 153, 157); Microsoft Q&A (disco 7 e 51, WHEA 17, 18, 19 e 47, Kernel-Power 41).
        Agrupa por provedor, ID, nível e disco físico e indica se é o disco do sistema: pen drive e cartão geram muitos
        eventos sem relação com o disco interno. Modelo e barramento são do disco conectado agora com aquele número.
    #>
    param([int]$Dias = $script:DiasEventos)
    $inicio = (Get-Date).AddDays(-$Dias)
    $lista = New-Object System.Collections.Generic.List[object]
    $adicionar = { param($Categoria, $Eventos) foreach ($e in @($Eventos)) { if ($e) { $lista.Add([pscustomobject]@{ Categoria = $Categoria; Evento = $e }) } } }
    foreach ($prov in 'disk', 'Ntfs', 'Microsoft-Windows-Ntfs') {
        & $adicionar 'Disco' @(Get-EventoSistema @{ ProviderName = $prov; Level = 1, 2, 3; StartTime = $inicio })
    }
    & $adicionar 'Disco' @(Get-EventoSistema @{ Id = 129; Level = 1, 2, 3; StartTime = $inicio } | Where-Object { $_.ProviderName -match '(?i)stor|nvme|ahci|raid|scsi' })
    & $adicionar 'Hardware' @(Get-EventoSistema @{ ProviderName = 'Microsoft-Windows-WHEA-Logger'; Level = 1, 2, 3; StartTime = $inicio })
    & $adicionar 'Desligamento inesperado' @(Get-EventoSistema @{ ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; StartTime = $inicio })

    $mapa = Get-MapaDisco
    $discos = @{}
    foreach ($d in @(Get-Disk -ErrorAction SilentlyContinue)) { $discos[[int]$d.Number] = $d }
    $discoSistema = try { [int](Get-Partition -DriveLetter $env:SystemDrive.Substring(0, 1) -ErrorAction Stop).DiskNumber } catch { $null }

    $itens = foreach ($x in $lista) {
        $e = $x.Evento
        $dv = if ($x.Categoria -eq 'Disco') { Get-DispositivoEvento $e } else { [pscustomobject]@{ Volume = $null; Dispositivo = $null } }
        $n = Resolve-DiscoEvento -Dispositivo $dv.Dispositivo -Volume $dv.Volume -Mapa $mapa
        # Letra que não existe mais: o volume estava num disco removido (o disco do sistema está sempre conectado).
        $desconectado = $null -eq $n -and [string]$dv.Volume -match '^[A-Za-z]:$'
        [pscustomobject]@{
            Categoria = $x.Categoria; Provedor = $e.ProviderName; Id = [int]$e.Id; Nivel = [int]$e.Level; Disco = $n; Desconectado = $desconectado; Data = $e.TimeCreated
            Ref       = if ($null -ne $n) { "Disco $n" } elseif ($desconectado) { "$($dv.Volume) (desconectado)" } elseif ($dv.Volume) { $dv.Volume }
            elseif ($dv.Dispositivo) { $dv.Dispositivo -replace '\\DR\d+$', '' } else { $null }
        }
    }
    $grupos = @($itens | Group-Object -Property Categoria, Provedor, Id, Nivel, Ref | ForEach-Object {
            $g = @($_.Group | Sort-Object -Property Data)
            $p = $g[0]
            $disco = if ($null -ne $p.Disco -and $discos.ContainsKey($p.Disco)) { $discos[$p.Disco] } else { $null }
            [pscustomobject]@{
                Categoria      = $p.Categoria
                Provedor       = $p.Provedor
                Id             = $p.Id
                Nivel          = $p.Nivel
                Dispositivo    = $p.Ref
                Disco          = $p.Disco
                Modelo         = if ($disco) { $disco.FriendlyName } else { $null }
                Barramento     = if ($disco) { [string]$disco.BusType } else { $null }
                DiscoDoSistema = if ($null -ne $p.Disco -and $null -ne $discoSistema) { $p.Disco -eq $discoSistema } elseif ($p.Desconectado) { $false } else { $null }
                Quantidade     = $g.Count
                Primeiro       = ConvertTo-DataIso $g[0].Data
                Ultimo         = ConvertTo-DataIso $g[-1].Data
            }
        })
    $soma = { param($Filtro) [int](@($grupos | Where-Object $Filtro) | Measure-Object -Property Quantidade -Sum).Sum }
    [pscustomobject]@{
        Dias   = $Dias
        Resumo = [pscustomobject]@{
            DiscoDoSistemaErros      = & $soma { $_.Categoria -eq 'Disco' -and $_.DiscoDoSistema -eq $true -and $_.Nivel -le 2 }
            DiscoDoSistemaAvisos     = & $soma { $_.Categoria -eq 'Disco' -and $_.DiscoDoSistema -eq $true -and $_.Nivel -eq 3 }
            OutrosDiscos             = & $soma { $_.Categoria -eq 'Disco' -and $_.DiscoDoSistema -eq $false }
            DiscoNaoIdentificado     = & $soma { $_.Categoria -eq 'Disco' -and $null -eq $_.DiscoDoSistema }
            HardwareFatal            = & $soma { $_.Categoria -eq 'Hardware' -and $_.Nivel -le 2 }
            HardwareCorrigido        = & $soma { $_.Categoria -eq 'Hardware' -and $_.Nivel -eq 3 }
            DesligamentosInesperados = & $soma { $_.Categoria -eq 'Desligamento inesperado' }
        }
        Grupos = $grupos
    }
}

function Invoke-PowercfgRelatorio {
    param([Parameter(Mandatory)][string[]]$Argumentos)
    $saida = & "$env:windir\System32\powercfg.exe" @Argumentos 2>&1
    if ($LASTEXITCODE -ne 0) { throw "powercfg $($Argumentos -join ' ') falhou ($LASTEXITCODE): $($saida | Out-String)" }
}

function ConvertFrom-RelatorioBateria {
    <# Capacidades do XML do powercfg /batteryreport /xml (esquema http://schemas.microsoft.com/battery/2012). #>
    param([Parameter(Mandatory)][xml]$Xml)
    foreach ($b in @($Xml.BatteryReport.Batteries.Battery)) {
        if (-not $b) { continue }
        $projetada = [double]$b.DesignCapacity
        $atual = [double]$b.FullChargeCapacity
        [pscustomobject]@{
            Id           = $b.Id
            Fabricante   = $b.Manufacturer
            Quimica      = $b.Chemistry
            ProjetadaMWh = $projetada
            AtualMWh     = $atual
            SaudePct     = if ($projetada -gt 0) { [math]::Round(100 * $atual / $projetada, 1) } else { $null }
            # 0 em alguns modelos significa "não informado pelo fabricante".
            Ciclos       = [int]$b.CycleCount
        }
    }
}

function Get-SecaoBateria {
    <#
        M7. Só com bateria. powercfg /batteryreport: HTML na pasta de saída para mostrar ao cliente e XML, lido e apagado,
        para os números. /duration 1 limita os horários de uso do relatório ao último dia (LGPD).
    #>
    param([Parameter(Mandatory)][string]$Pasta, [Parameter(Mandatory)][string]$Prefixo)
    if (-not @(Get-CimInstance Win32_Battery).Count) { return $null }
    $html = Join-Path $Pasta "$($Prefixo)_bateria.html"
    $arqXml = Join-Path $env:TEMP ('bateria-{0}.xml' -f [guid]::NewGuid())
    try {
        Invoke-PowercfgRelatorio -Argumentos @('/batteryreport', '/output', $arqXml, '/xml', '/duration', '1')
        $doc = New-Object Xml.XmlDocument
        $doc.Load($arqXml)
        $baterias = @(ConvertFrom-RelatorioBateria -Xml $doc)
    }
    finally { Remove-Item -LiteralPath $arqXml -Force -ErrorAction SilentlyContinue }
    Invoke-PowercfgRelatorio -Argumentos @('/batteryreport', '/output', $html, '/duration', '1')
    [pscustomobject]@{ Relatorio = $html; Baterias = $baterias }
}

#endregion

#region Comparação

function Get-MetricaColeta {
    <# Extrai as métricas comparáveis. Melhor = direção desejada após a otimização. #>
    param($Coleta)
    $res = $Coleta.Desempenho.Resumo
    $sistema = $Coleta.Discos.Volumes | Where-Object { "$($_.Letra):" -eq $Coleta.Sistema.DriveSistema } | Select-Object -First 1
    $inic = @($Coleta.Inicializacao.Maquina) + @($Coleta.Inicializacao.Usuario) | Where-Object { $_ -and $_.Estado -eq 'Habilitado' }
    $boot = @($Coleta.Boot) | Where-Object { $_ } | Select-Object -First 1
    @(
        [pscustomobject]@{ Metrica = 'Tempo de boot (s)'; Valor = if ($boot) { [math]::Round($boot.BootTime / 1000, 1) } else { $null }; Melhor = 'Menor' }
        [pscustomobject]@{ Metrica = 'Pós-boot até ocioso (s)'; Valor = if ($boot) { [math]::Round($boot.BootPostBootTime / 1000, 1) } else { $null }; Melhor = 'Menor' }
        [pscustomobject]@{ Metrica = 'CPU em repouso, média (%)'; Valor = $res.CpuPct.Media; Melhor = 'Menor' }
        [pscustomobject]@{ Metrica = 'Memória disponível, média (MB)'; Valor = $res.MemDisponivelMB.Media; Melhor = 'Maior' }
        [pscustomobject]@{ Metrica = 'Memória comprometida, média (%)'; Valor = $res.CommitPct.Media; Melhor = 'Menor' }
        [pscustomobject]@{ Metrica = 'Paginação, média (páginas/s)'; Valor = $res.PaginasSeg.Media; Melhor = 'Menor' }
        [pscustomobject]@{ Metrica = 'Disco ocioso, média (%)'; Valor = $res.DiscoOciosoPct.Media; Melhor = 'Maior' }
        [pscustomobject]@{ Metrica = 'Processos em execução'; Valor = $Coleta.Desempenho.TotalProcessos; Melhor = 'Menor' }
        [pscustomobject]@{ Metrica = 'Serviços em execução'; Valor = @($Coleta.Servicos | Where-Object { $_.Estado -eq 'Running' }).Count; Melhor = 'Menor' }
        [pscustomobject]@{ Metrica = 'Itens de inicialização habilitados'; Valor = @($inic).Count; Melhor = 'Menor' }
        [pscustomobject]@{ Metrica = 'Tarefas de terceiros habilitadas'; Valor = @($Coleta.Tarefas | Where-Object { $_.Estado -ne 'Disabled' }).Count; Melhor = 'Menor' }
        [pscustomobject]@{ Metrica = 'Temporários e caches (MB)'; Valor = $Coleta.Armazenamento.TotalMB; Melhor = 'Menor' }
        # Coletas anteriores à 1.3.0 não têm a seção: Sem dado, em vez de zero.
        [pscustomobject]@{ Metrica = 'Programas e apps instalados'; Valor = if ($Coleta.PSObject.Properties['Programas']) { @($Coleta.Programas | Where-Object { $_ }).Count } else { $null }; Melhor = 'Menor' }
        [pscustomobject]@{ Metrica = 'Espaço livre no disco do sistema (GB)'; Valor = if ($sistema) { $sistema.LivreGB } else { $null }; Melhor = 'Maior' }
    )
}

function Compare-Coleta {
    <#
        Compara uma ou mais coletas "antes" com a coleta "depois".
        Com duas ou mais coletas antes, o intervalo [mínimo, máximo] delas é a faixa de ruído da máquina:
        valor depois dentro da faixa = "Dentro do ruído"; fora dela = melhorou ou piorou.
        Com uma coleta antes, não há faixa e qualquer diferença é classificada (com aviso).
    #>
    param([Parameter(Mandatory)]$Antes, [Parameter(Mandatory)]$Depois)
    $listas = New-Object System.Collections.Generic.List[object]
    foreach ($a in @($Antes)) { $listas.Add(@(Get-MetricaColeta $a)) }
    $d = @(Get-MetricaColeta $Depois)

    for ($i = 0; $i -lt $d.Count; $i++) {
        $valores = @(foreach ($l in $listas) { if ($null -ne $l[$i].Valor) { [double]$l[$i].Valor } })
        $vd = $d[$i].Valor
        $menor = $d[$i].Melhor -eq 'Menor'
        $media = $null; $faixa = $null; $dif = $null; $pct = $null; $resultado = 'Sem dado'

        if ($valores.Count -and $null -ne $vd) {
            $m = $valores | Measure-Object -Average -Minimum -Maximum
            $media = [math]::Round($m.Average, 1)
            $dif = [math]::Round($vd - $m.Average, 1)
            if ($m.Average -ne 0) { $pct = [math]::Round(100 * ($vd - $m.Average) / [math]::Abs($m.Average), 1) }
            if ($valores.Count -ge 2) { $faixa = '{0} a {1}' -f $m.Minimum, $m.Maximum }

            $resultado = if ($vd -eq $m.Minimum -and $vd -eq $m.Maximum) { 'Igual' }
            elseif ($valores.Count -ge 2 -and $vd -ge $m.Minimum -and $vd -le $m.Maximum) { 'Dentro do ruído' }
            elseif ($valores.Count -ge 2) { if (($vd -lt $m.Minimum) -eq $menor) { 'Melhorou' } else { 'Piorou' } }
            elseif (($vd -lt $m.Average) -eq $menor) { 'Melhorou' } else { 'Piorou' }
        }
        [pscustomobject]@{
            Metrica = $d[$i].Metrica; Antes = $media; FaixaAntes = $faixa; Depois = $vd
            Diferenca = $dif; DiferencaPct = $pct; Resultado = $resultado
        }
    }
}

function Get-AvisoCondicao {
    <# Diferenças de condição que invalidam ou enfraquecem a comparação. #>
    param($Antes, $Depois)
    $avisos = New-Object System.Collections.Generic.List[string]
    $lista = @($Antes)
    if ($lista.Count -lt 2) {
        $avisos.Add('Apenas uma coleta antes: sem faixa de ruído. Diferenças de CPU, memória, paginação e disco podem ser variação normal.')
    }
    elseif (@($lista | ForEach-Object { $_.Sistema.UltimoBoot } | Select-Object -Unique).Count -lt $lista.Count) {
        $avisos.Add('Coletas antes sem reinicialização entre elas: a faixa de ruído pode estar subestimada.')
    }
    foreach ($a in $lista) {
        $msgs = @(
            if ($a.Computador -ne $Depois.Computador) { "Computadores diferentes: $($a.Computador) e $($Depois.Computador)." }
            if ($a.AmostraSegundos -ne $Depois.AmostraSegundos) { 'Durações de amostragem diferentes.' }
            if ([math]::Abs($a.Sistema.UptimeMinutos - $Depois.Sistema.UptimeMinutos) -gt 15) { "Tempo desde o boot difere mais de 15 min ($($a.Sistema.UptimeMinutos) e $($Depois.Sistema.UptimeMinutos) min)." }
            if ($a.Energia.NaBateria -ne $Depois.Energia.NaBateria) { 'Fonte de energia diferente (bateria e tomada).' }
            if ($a.Elevado -ne $Depois.Elevado) { 'Uma coleta foi elevada e a outra não: seções disponíveis diferem.' }
            if ("$($a.Sistema.Build).$($a.Sistema.UBR)" -ne "$($Depois.Sistema.Build).$($Depois.Sistema.UBR)") { 'Build do Windows mudou entre as coletas (atualização instalada).' }
        )
        foreach ($m in $msgs) { if (-not $avisos.Contains($m)) { $avisos.Add($m) } }
    }
    $avisos
}

function Export-ComparacaoHtml {
    param($Antes, $Depois, $Linhas, $Avisos, [string]$Caminho)
    $enc = { param($t) [Net.WebUtility]::HtmlEncode([string]$t) }
    $cores = @{ Melhorou = '#1b7f3b'; Piorou = '#b3261e'; Igual = '#555'; 'Dentro do ruído' = '#555'; 'Sem dado' = '#999' }
    $linhasHtml = foreach ($l in $Linhas) {
        $pct = if ($null -ne $l.DiferencaPct) { " ($($l.DiferencaPct)%)" } else { '' }
        "<tr><td>$(& $enc $l.Metrica)</td><td>$(& $enc $l.Antes)</td><td>$(& $enc $l.FaixaAntes)</td><td>$(& $enc $l.Depois)</td><td>$(& $enc $l.Diferenca)$pct</td><td style='color:$($cores[$l.Resultado])'>$(& $enc $l.Resultado)</td></tr>"
    }
    $avisosHtml = if (@($Avisos).Count) { '<h2>Atenção</h2><ul>' + (($Avisos | ForEach-Object { "<li>$(& $enc $_)</li>" }) -join '') + '</ul>' } else { '' }

    $colecoes = @($Antes) + @($Depois)
    $titulos = @(for ($i = 1; $i -le @($Antes).Count; $i++) { "Antes $i" }) + 'Depois'
    $condicoes = [ordered]@{
        'Data da coleta'               = { param($c) $c.DataColeta }
        'Windows'                      = { param($c) "$($c.Sistema.Produto) $($c.Sistema.Build).$($c.Sistema.UBR)" }
        'Último boot'                  = { param($c) $c.Sistema.UltimoBoot }
        'Minutos desde o boot'         = { param($c) $c.Sistema.UptimeMinutos }
        'Amostragem (s)'               = { param($c) $c.AmostraSegundos }
        'Na bateria'                   = { param($c) $c.Energia.NaBateria }
        'Executado como administrador' = { param($c) $c.Elevado }
    }
    $cabecalho = '<tr><th>Condição</th>' + (($titulos | ForEach-Object { "<th>$_</th>" }) -join '') + '</tr>'
    $cond = foreach ($nome in $condicoes.Keys) {
        "<tr><td>$(& $enc $nome)</td>" + (($colecoes | ForEach-Object { "<td>$(& $enc (& $condicoes[$nome] $_))</td>" }) -join '') + '</tr>'
    }
    $html = @"
<!DOCTYPE html>
<html lang="pt-BR"><head><meta charset="utf-8"><title>Comparação $(& $enc $Depois.Computador)</title>
<style>body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#222}table{border-collapse:collapse;margin-bottom:24px}
th,td{border:1px solid #ccc;padding:6px 10px;text-align:left}th{background:#f0f0f0}</style></head><body>
<h1>Antes e depois: $(& $enc $Depois.Computador)</h1>
$avisosHtml
<h2>Métricas</h2>
<table><tr><th>Métrica</th><th>Antes (média)</th><th>Faixa antes</th><th>Depois</th><th>Diferença</th><th>Resultado</th></tr>
$($linhasHtml -join "`n")
</table>
<p>"Dentro do ruído": o valor depois está entre o menor e o maior valor medido nas coletas antes, sem nenhuma mudança na máquina. A diferença não pode ser atribuída à otimização.</p>
<h2>Condições das coletas</h2>
<table>$cabecalho
$($cond -join "`n")
</table>
</body></html>
"@
    $html | Out-File -LiteralPath $Caminho -Encoding UTF8
}

#endregion

#region Execução

function Invoke-Coleta {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'UsuarioSid', Justification = 'Usado no scriptblock passado a Invoke-Secao.')]
    param([string]$UsuarioSid, [int]$AmostraSegundos, [int]$AguardarUptimeMinutos, [string]$PastaSaida)
    $script:Erros = New-Object System.Collections.Generic.List[object]
    $elevado = Test-Administrador
    if (-not $elevado) { Write-Warning 'Executando sem administrador: algumas seções ficarão indisponíveis.' }

    if ($AguardarUptimeMinutos -gt 0) {
        $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
        $alvo = $boot.AddMinutes($AguardarUptimeMinutos)
        while ((Get-Date) -lt $alvo) {
            Write-Progress -Activity "Aguardando $AguardarUptimeMinutos min desde o boot" -SecondsRemaining ([int]($alvo - (Get-Date)).TotalSeconds)
            Start-Sleep -Seconds 5
        }
        Write-Progress -Activity 'Aguardando' -Completed
    }

    $alvo = Invoke-Secao 'Usuário alvo' { Get-UsuarioAlvo -Sid $UsuarioSid }
    $sistema = Invoke-Secao 'Sistema' { Get-SecaoSistema }
    if ($sistema) { $sistema | Add-Member -NotePropertyName DriveSistema -NotePropertyValue $env:SystemDrive }
    # Desempenho primeiro: as demais seções geram carga que distorceria o repouso.
    $desempenho = Invoke-Secao 'Desempenho' { Get-SecaoDesempenho -Segundos $AmostraSegundos }
    $usuario = if ($alvo) { Invoke-Secao 'Hive do usuário' { Get-SecaoUsuario -Alvo $alvo } } else { $null }
    if (-not (Test-Path -LiteralPath $PastaSaida)) { New-Item -ItemType Directory -Path $PastaSaida -Force | Out-Null }
    $prefixo = '{0}_{1}' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmmss')

    $rel = [ordered]@{
        VersaoColeta    = $script:VersaoColeta
        DataColeta      = ConvertTo-DataIso (Get-Date)
        Computador      = $env:COMPUTERNAME
        Elevado         = $elevado
        AmostraSegundos = $AmostraSegundos
        Sistema         = $sistema
        Hardware        = Invoke-Secao 'Hardware' { Get-SecaoHardware }
        Discos          = Invoke-Secao 'Discos' { Get-SecaoDisco }
        BitLocker       = @(Invoke-Secao 'BitLocker' { Get-SecaoBitLocker })
        Desempenho      = $desempenho
        Inicializacao   = [pscustomobject]@{
            Maquina = @(Invoke-Secao 'Inicialização da máquina' { Get-SecaoInicializacaoMaquina })
            Usuario = if ($usuario) { @($usuario.Inicializacao) } else { @() }
        }
        Tarefas         = @(Invoke-Secao 'Tarefas agendadas' { Get-SecaoTarefa })
        Servicos        = @(Invoke-Secao 'Serviços' { Get-SecaoServico })
        Energia         = Invoke-Secao 'Energia' { Get-SecaoEnergia }
        Visual          = if ($usuario) { $usuario.Visual } else { $null }
        Armazenamento   = Invoke-Secao 'Armazenamento' { Get-SecaoArmazenamento }
        Atualizacoes    = Invoke-Secao 'Atualizações' { Get-SecaoAtualizacao }
        Boot            = @(Invoke-Secao 'Boot' { Get-SecaoBoot })
        Antivirus       = @(Invoke-Secao 'Antivírus' { Get-SecaoProtecao })
        Programas       = @(@(Invoke-Secao 'Programas' { Get-SecaoPrograma -Elevado $elevado }) + $(if ($usuario) { @($usuario.Programas) } else { @() }) |
                Where-Object { $_ } | Sort-Object -Property Nome)
        Dispositivos    = @(Invoke-Secao 'Dispositivos' { Get-SecaoDispositivo })
        EventosHardware = Invoke-Secao 'Eventos de hardware' { Get-SecaoEventoHardware }
        Bateria         = Invoke-Secao 'Bateria' { Get-SecaoBateria -Pasta $PastaSaida -Prefixo $prefixo }
        Erros           = $null
    }
    # Indexador e ToArray(): no PS 5.1, $rel.Erros = @($lista) lança ArgumentException em [ordered].
    $rel['Erros'] = $script:Erros.ToArray()

    $arquivo = Join-Path $PastaSaida "$prefixo.json"
    [pscustomobject]$rel | ConvertTo-Json -Depth 8 | Out-File -LiteralPath $arquivo -Encoding UTF8
    if ($script:Erros.Count) { Write-Warning "$($script:Erros.Count) seção(ões) com erro. Ver campo Erros no JSON." }
    Get-Item -LiteralPath $arquivo
}

function Invoke-Comparacao {
    param([string[]]$Antes, [string]$Depois, [string]$SaidaHtml)
    # Via powershell.exe -File, 'a.json,b.json' chega como um único texto.
    $arquivos = @($Antes | ForEach-Object { if (Test-Path -LiteralPath $_) { $_ } else { $_ -split ',' } })
    $a = @($arquivos | ForEach-Object { Get-Content -LiteralPath $_ -Raw -Encoding UTF8 | ConvertFrom-Json })
    $d = Get-Content -LiteralPath $Depois -Raw -Encoding UTF8 | ConvertFrom-Json
    $linhas = @(Compare-Coleta -Antes $a -Depois $d)
    $avisos = @(Get-AvisoCondicao -Antes $a -Depois $d)
    if (-not $SaidaHtml) {
        $SaidaHtml = Join-Path (Split-Path -Parent (Resolve-Path -LiteralPath $Depois)) ('{0}_comparacao_{1}.html' -f $d.Computador, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    }
    Export-ComparacaoHtml -Antes $a -Depois $d -Linhas $linhas -Avisos $avisos -Caminho $SaidaHtml
    foreach ($av in $avisos) { Write-Warning $av }
    $linhas
    Get-Item -LiteralPath $SaidaHtml
}

# Permite carregar as funções com dot-source (testes) sem executar.
if ($MyInvocation.InvocationName -ne '.') {
    if ($Comparar) {
        Invoke-Comparacao -Antes $Antes -Depois $Depois -SaidaHtml $SaidaHtml
    }
    else {
        # Padrão resolvido aqui: no PS 5.1 com -File, $PSScriptRoot chega vazio no bloco param.
        if (-not $PastaSaida) { $PastaSaida = Join-Path $PSScriptRoot 'relatorios' }
        Invoke-Coleta -UsuarioSid $UsuarioSid -AmostraSegundos $AmostraSegundos -AguardarUptimeMinutos $AguardarUptimeMinutos -PastaSaida $PastaSaida
    }
}

#endregion
