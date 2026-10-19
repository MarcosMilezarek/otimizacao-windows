<#
.SYNOPSIS
    Manutenção do Windows (itens M1 a M4 e M8 do catálogo) conforme o perfil do cliente: integridade da imagem e
    dos arquivos de sistema, verificação do sistema de arquivos, TRIM e horário ativo do Windows Update.

.DESCRIPTION
    Aplica somente os itens M* listados em Aplicar no perfil e não listados em Pular. Ordem: M4, M8, M3, M1, M2.
    M5 a M7 (dispositivos com erro, eventos de hardware, relatório de bateria) são só leitura e ficam na Coleta.

      M1  Imagem do Windows (repositório de componentes): Repair-WindowsImage -Online -ScanHealth, só leitura.
          Com Opcoes.M1Reparar = $true e corrupção reparável: -RestoreHealth, que baixa arquivos pelo Windows Update,
          e nova verificação. Leva vários minutos.
      M2  Arquivos de sistema: sfc /verifyonly, só leitura. O resultado vem das entradas [SR] do CBS.log, porque o
          código de saída do sfc não é documentado e o texto na tela é traduzido. Com Opcoes.M2Reparar = $true e
          violações encontradas: sfc /scannow e nova verificação. Roda depois do M1 (ordem recomendada pela Microsoft).
      M3  Sistema de arquivos: Repair-Volume -Scan (equivalente a chkdsk /scan, online) em cada volume fixo NTFS ou
          ReFS com letra. Só verifica; erro encontrado gera recomendação de reparo numa janela de manutenção.
      M4  TRIM do NTFS ligado quando há SSD: lê DisableDeleteNotification em
          HKLM\SYSTEM\CurrentControlSet\Control\FileSystem e corrige com fsutil behavior set DisableDeleteNotify 0
          (padrão do Windows). A tarefa de otimização de unidades fica com o L8 (Limpeza).
      M8  Horário ativo do Windows Update pelas políticas SetActiveHours, ActiveHoursStart e ActiveHoursEnd em
          HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate. Horas em Opcoes.M8Inicio e Opcoes.M8Fim (0 a 23,
          intervalo de 1 a 18 h). Pulado se já houver política com outro valor (GPO, MDM) e no Windows Home.

    Ponto de restauração e backup dos valores originais em %ProgramData%\Otimizacao\<Cliente>\<data>-Manutencao
    somente quando algum item selecionado altera o sistema (M4, M8, ou M1 e M2 com reparo aprovado).

.PARAMETER Perfil
    Arquivo .psd1 do cliente.

.PARAMETER Revert
    Reverte todas as sessões de aplicação ainda não revertidas, da mais recente para a mais antiga (ou só a indicada
    em -Sessao): TRIM e políticas do horário ativo voltam ao original. Reparos do M1 e do M2 não têm reversão própria;
    o caminho de volta é o ponto de restauração criado antes deles.

.PARAMETER Sessao
    Pasta da sessão a reverter.

.PARAMETER PermitirReinicializacaoPendente
    Não bloqueia a execução quando há reinicialização pendente.

.EXAMPLE
    .\Manutencao.ps1 -Perfil .\perfis\ClienteX.psd1 -WhatIf

.EXAMPLE
    .\Manutencao.ps1 -Perfil .\perfis\ClienteX.psd1 -Revert

.NOTES
    O que se perde: M8 impede o usuário de mudar o horário ativo em Configurações ("gerenciado pela organização")
    e desliga o ajuste automático do horário ativo. M1 com reparo consome banda de internet. M1, M2 e M3 mantêm disco
    e CPU ocupados por vários minutos.
    Reversão: -Revert restaura M4 e M8. M1, M2 e M3 só leem, exceto os reparos aprovados.
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

$script:NomeScript = 'Manutencao'
$script:HKLM = 'Registry::HKEY_LOCAL_MACHINE'
$script:SubChaveFs = 'SYSTEM\CurrentControlSet\Control\FileSystem'
$script:SubChaveWu = 'SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'

#region Auxiliares

function Get-Opcao {
    param($Perfil, [string]$Nome)
    if ($Perfil.Opcoes -and $Perfil.Opcoes.ContainsKey($Nome)) { $Perfil.Opcoes[$Nome] } else { $null }
}

function Write-Achado {
    <# Resultado de diagnóstico que pede ação do técnico: linha Info com ATENÇÃO e aviso na tela. #>
    param($Sessao, [string]$Item, [string]$Alvo, $ValorAnterior, [string]$Detalhe)
    Write-Warning "[$Item] $Alvo : $Detalhe"
    Write-LogOtimizacao -Sessao $Sessao -Item $Item -Alvo $Alvo -ValorAnterior $ValorAnterior -Resultado Info -Detalhe "ATENÇÃO: $Detalhe" | Out-Null
}

function Invoke-Fsutil {
    param([Parameter(Mandatory)][string[]]$Argumentos)
    $saida = & "$env:windir\System32\fsutil.exe" @Argumentos 2>&1
    if ($LASTEXITCODE -ne 0) { throw "fsutil $($Argumentos -join ' ') falhou ($LASTEXITCODE): $($saida | Out-String)" }
}

#endregion

#region M1 imagem do Windows

function Get-SaudeImagem {
    <# ImageHealthState de Repair-WindowsImage -ScanHealth: Healthy, Repairable ou NonRepairable. #>
    [string](Repair-WindowsImage -Online -ScanHealth -NoRestart -ErrorAction Stop).ImageHealthState
}

function Invoke-M1 {
    param($Sessao, [bool]$Reparar)
    $alvo = 'Imagem do Windows (repositório de componentes)'
    if ($Sessao.Simular) {
        $det = if ($Reparar) { 'Verificação (só leitura); com corrupção reparável, RestoreHealth (download pelo Windows Update) e nova verificação.' }
        else { 'Verificação (só leitura). Reparo não aprovado (Opcoes.M1Reparar).' }
        return Write-LogOtimizacao -Sessao $Sessao -Item 'M1' -Alvo $alvo -ValorNovo 'ScanHealth' -Resultado Simulado -Detalhe $det | Out-Null
    }
    $estado = Get-SaudeImagem
    switch ($estado) {
        'Healthy' {
            Write-LogOtimizacao -Sessao $Sessao -Item 'M1' -Alvo $alvo -ValorAnterior $estado -Resultado JaAplicado -Detalhe 'Sem corrupção.' | Out-Null
        }
        'Repairable' {
            if (-not $Reparar) {
                return Write-Achado -Sessao $Sessao -Item 'M1' -Alvo $alvo -ValorAnterior $estado -Detalhe 'Corrupção reparável. Para reparar, aprove Opcoes.M1Reparar no perfil (RestoreHealth baixa arquivos pelo Windows Update).'
            }
            $r = Repair-WindowsImage -Online -RestoreHealth -NoRestart -ErrorAction Stop
            $depois = Get-SaudeImagem
            if ($depois -ne 'Healthy') { throw "A imagem continua $depois após RestoreHealth. Reparo in-place com a mídia de instalação." }
            $det = if ($r -and $r.PSObject.Properties['RestartNeeded'] -and $r.RestartNeeded) { 'Reinicialização necessária para concluir.' } else { $null }
            Write-LogOtimizacao -Sessao $Sessao -Item 'M1' -Alvo $alvo -ValorAnterior $estado -ValorNovo $depois -Resultado OK -Detalhe $det | Out-Null
        }
        default {
            Write-Achado -Sessao $Sessao -Item 'M1' -Alvo $alvo -ValorAnterior $estado -Detalhe 'Corrupção não reparável pelo DISM. Reparo in-place (atualização com a mídia de instalação) ou reinstalação.'
        }
    }
}

#endregion

#region M2 arquivos de sistema

function Get-EntradaSr {
    <#
        Linhas do SFC no CBS.log gravadas a partir de Desde. Formato documentado: "<data> <hora>, Info CSI ... [SR] ..."
        (learn.microsoft.com/troubleshoot/windows-client/installing-updates-features-roles/analyze-sfc-program-log-file-entries).
        Lê também logs CbsPersist_* rotacionados durante a execução. Abre com compartilhamento: o CBS.log fica em uso.
        O CBS.log é lido sempre: aberto pelo TrustedInstaller, a data de modificação dele não avança (medido na VM:
        conteúdo até 09:30, data do arquivo 09:12). Só os logs rotacionados, já fechados, são filtrados pela data.
    #>
    param([Parameter(Mandatory)][datetime]$Desde, [string]$Pasta = (Join-Path $env:windir 'Logs\CBS'))
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $limite = $Desde.AddSeconds(-1)
    foreach ($arq in @(Get-ChildItem -LiteralPath $Pasta -Filter '*.log' -File -ErrorAction Stop | Where-Object { $_.Name -eq 'CBS.log' -or $_.LastWriteTime -ge $limite })) {
        $fs = [IO.File]::Open($arq.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete')
        try {
            $leitor = New-Object IO.StreamReader($fs)
            while ($null -ne ($l = $leitor.ReadLine())) {
                if (-not ($l.Contains('[SR]') -or $l.Contains('Cannot repair member file'))) { continue }
                if ($l -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}),' -and [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', $inv) -ge $limite) { $l }
            }
        }
        finally { $fs.Dispose() }
    }
}

function Get-ResultadoSfc {
    <# Classifica as linhas [SR]: verificação concluída, arquivos com problema e arquivos não reparáveis. #>
    param([string[]]$Linhas)
    $l = @($Linhas | Where-Object { $_ })
    [pscustomobject]@{
        Concluido     = [bool]@($l | Where-Object { $_.Contains('[SR] Verify complete') }).Count
        Problemas     = @($l | Where-Object { $_.Contains('Repairing corrupted file') -or $_.Contains('Repaired file') -or $_.Contains('Cannot repair member file') }).Count
        NaoReparaveis = @($l | Where-Object { $_.Contains('Cannot repair member file') }).Count
    }
}

function Invoke-Sfc {
    <# Executa o sfc e devolve o resultado lido do CBS.log (o texto na tela é traduzido e o código de saída não é documentado). #>
    param([Parameter(Mandatory)][ValidateSet('/verifyonly', '/scannow')][string]$Modo)
    $inicio = Get-Date
    & "$env:windir\System32\sfc.exe" $Modo | Out-Null
    $codigo = $LASTEXITCODE
    $r = Get-ResultadoSfc -Linhas @(Get-EntradaSr -Desde $inicio)
    $r | Add-Member -NotePropertyName CodigoSaida -NotePropertyValue $codigo
    $r
}

function Invoke-M2 {
    param($Sessao, [bool]$Reparar)
    $alvo = 'Arquivos de sistema (SFC)'
    if ($Sessao.Simular) {
        $det = if ($Reparar) { 'sfc /verifyonly (só leitura); com violações, sfc /scannow e nova verificação.' }
        else { 'sfc /verifyonly (só leitura). Reparo não aprovado (Opcoes.M2Reparar).' }
        return Write-LogOtimizacao -Sessao $Sessao -Item 'M2' -Alvo $alvo -ValorNovo '/verifyonly' -Resultado Simulado -Detalhe $det | Out-Null
    }
    $v = Invoke-Sfc -Modo '/verifyonly'
    if (-not $v.Concluido) { throw "Verificação sem conclusão registrada no CBS.log (código do sfc $($v.CodigoSaida))." }
    if (-not $v.Problemas) {
        return Write-LogOtimizacao -Sessao $Sessao -Item 'M2' -Alvo $alvo -ValorAnterior 'sem violações' -Resultado JaAplicado | Out-Null
    }
    $antes = "$($v.Problemas) arquivo(s) com violação"
    if (-not $Reparar) {
        return Write-Achado -Sessao $Sessao -Item 'M2' -Alvo $alvo -ValorAnterior $antes -Detalhe 'Violações encontradas. Para reparar, aprove Opcoes.M2Reparar no perfil. Detalhes: linhas [SR] de %windir%\Logs\CBS\CBS.log.'
    }
    Invoke-Sfc -Modo '/scannow' | Out-Null
    $d = Invoke-Sfc -Modo '/verifyonly'
    if (-not $d.Concluido) { throw "Verificação após o reparo sem conclusão registrada no CBS.log (código do sfc $($d.CodigoSaida))." }
    if ($d.Problemas) { throw "$($d.Problemas) arquivo(s) continuam com violação após sfc /scannow. Ver linhas [SR] do CBS.log." }
    Write-LogOtimizacao -Sessao $Sessao -Item 'M2' -Alvo $alvo -ValorAnterior $antes -ValorNovo 'sem violações' -Resultado OK | Out-Null
}

#endregion

#region M3 sistema de arquivos

# Volume.RepairStatus do módulo Storage (Volume.cdxml do Windows): nome por código, para quando a saída vier numérica.
$script:StatusReparo = @{
    0 = 'NoErrorsFound'; 1 = 'ErrorsFixed'; 2 = 'MinorErrorsFixedOrCleanup'; 3 = 'Failed'; 4 = 'ScanNoErrorsFound'
    5 = 'ScanErrorsFoundAndFixedOnline'; 6 = 'ScanErrorsFixedOnlineAlsoNeedSpotFix'; 7 = 'ScanErrorsFoundNeedSpotFix'
    8 = 'ScanNeedsRetry'; 9 = 'ScanRunning'; 10 = 'ScanTransientSnapshotError'; 11 = 'ScanFatalSnapshotError'
    12 = 'ScanNeedsMetaDataRetry'; 13 = 'NeedOfflineScanAndFix'
}

function ConvertTo-StatusReparo {
    param($Valor)
    $t = [string]$Valor
    if ($t -match '^\d+$' -and $script:StatusReparo.ContainsKey([int]$t)) { return $script:StatusReparo[[int]$t] }
    $t
}

function Get-VolumeVerificavel {
    @(Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' -and $_.FileSystem -in 'NTFS', 'ReFS' } |
            Sort-Object -Property DriveLetter | ForEach-Object { [string]$_.DriveLetter })
}

function Invoke-M3 {
    param($Sessao)
    foreach ($letra in Get-VolumeVerificavel) {
        $alvo = "$($letra): (Repair-Volume -Scan)"
        if ($Sessao.Simular) {
            Write-LogOtimizacao -Sessao $Sessao -Item 'M3' -Alvo $alvo -ValorNovo 'verificação online (só leitura)' -Resultado Simulado | Out-Null
            continue
        }
        Invoke-ItemOtimizacao -Sessao $Sessao -Id 'M3' -Acao {
            $status = ConvertTo-StatusReparo (Repair-Volume -DriveLetter $letra -Scan -ErrorAction Stop)
            switch ($status) {
                { $_ -in 'NoErrorsFound', 'ScanNoErrorsFound' } {
                    Write-LogOtimizacao -Sessao $Sessao -Item 'M3' -Alvo $alvo -ValorAnterior $status -Resultado JaAplicado -Detalhe 'Sem erros.' | Out-Null
                }
                { $_ -in 'ScanErrorsFoundAndFixedOnline', 'ErrorsFixed', 'MinorErrorsFixedOrCleanup' } {
                    Write-LogOtimizacao -Sessao $Sessao -Item 'M3' -Alvo $alvo -ValorAnterior $status -Resultado Info -Detalhe 'Erros corrigidos online pelo próprio NTFS.' | Out-Null
                }
                { $_ -in 'ScanErrorsFixedOnlineAlsoNeedSpotFix', 'ScanErrorsFoundNeedSpotFix', 'NeedOfflineScanAndFix' } {
                    Write-Achado -Sessao $Sessao -Item 'M3' -Alvo $alvo -ValorAnterior $status -Detalhe "Erros que exigem reparo com o volume indisponível. Agendar janela: Repair-Volume -DriveLetter $letra -SpotFix (no disco do sistema roda na reinicialização). Fazer backup antes."
                }
                default { throw "Verificação não concluída ($status). Repetir mais tarde." }
            }
        }
    }
}

#endregion

#region M4 TRIM

function Test-TemSsd {
    [bool]@(Get-PhysicalDisk | Where-Object { [string]$_.MediaType -eq 'SSD' }).Count
}

function Get-EstadoTrim {
    <# DisableDeleteNotification do NTFS: ausente ou 0 = TRIM ligado (padrão, learn.microsoft.com fsutil-behavior). #>
    Get-ValorRegistro -Caminho "$($script:HKLM)\$($script:SubChaveFs)" -Nome 'DisableDeleteNotification'
}

function Invoke-M4 {
    param($Sessao)
    $alvo = 'TRIM do NTFS (DisableDeleteNotify)'
    if (-not (Test-TemSsd)) {
        return Write-LogOtimizacao -Sessao $Sessao -Item 'M4' -Alvo $alvo -Resultado Pulado -Detalhe 'Nenhum SSD identificado (HDD, VM ou RAID reportam outro tipo de mídia).' | Out-Null
    }
    $atual = Get-EstadoTrim
    $valor = if ($atual.Existe) { [int]$atual.Valor } else { 0 }
    if ($valor -eq 0) {
        return Write-LogOtimizacao -Sessao $Sessao -Item 'M4' -Alvo $alvo -ValorAnterior $valor -ValorNovo 0 -Resultado JaAplicado | Out-Null
    }
    if ($valor -ne 1) {
        return Write-LogOtimizacao -Sessao $Sessao -Item 'M4' -Alvo $alvo -ValorAnterior $valor -Resultado Pulado -Detalhe 'Valor fora do documentado (0 ou 1): nada feito.' | Out-Null
    }
    if ($Sessao.Simular) {
        return Write-LogOtimizacao -Sessao $Sessao -Item 'M4' -Alvo $alvo -ValorAnterior 1 -ValorNovo 0 -Resultado Simulado | Out-Null
    }
    Add-EstadoOriginal -Sessao $Sessao -Entrada @{ Tipo = 'Trim'; Item = 'M4'; Valor = 1 }
    Invoke-Fsutil -Argumentos @('behavior', 'set', 'DisableDeleteNotify', '0')
    $lido = Get-EstadoTrim
    if ($lido.Existe -and [int]$lido.Valor -ne 0) { throw 'TRIM continua desligado após fsutil.' }
    Write-LogOtimizacao -Sessao $Sessao -Item 'M4' -Alvo $alvo -ValorAnterior 1 -ValorNovo 0 -Resultado OK -Detalhe 'A Microsoft cita aparelhos raros que ficam mais lentos com TRIM: se o cliente notar lentidão, reverter.' | Out-Null
}

#endregion

#region M8 horário ativo

function Get-HorarioAtivo {
    <# Valida Opcoes.M8Inicio e M8Fim: horas 0 a 23 e intervalo de 1 a 18 h (máximo do Windows 10 1703 em diante, learn.microsoft.com waas-restart). #>
    param($Perfil)
    $ini = Get-Opcao $Perfil 'M8Inicio'
    $fim = Get-Opcao $Perfil 'M8Fim'
    if ($null -eq $ini -or $null -eq $fim) { return $null }
    if ([string]$ini -notmatch '^\d{1,2}$' -or [string]$fim -notmatch '^\d{1,2}$' -or [int]$ini -gt 23 -or [int]$fim -gt 23) {
        throw "Opcoes.M8Inicio e M8Fim devem ser horas de 0 a 23 (recebido $ini e $fim)."
    }
    $duracao = ([int]$fim - [int]$ini + 24) % 24
    if ($duracao -lt 1 -or $duracao -gt 18) { throw "Horário ativo de $ini h a $fim h tem $duracao h: o Windows aceita de 1 a 18 h." }
    [pscustomobject]@{ Inicio = [int]$ini; Fim = [int]$fim }
}

function Invoke-M8 {
    param($Sessao, $Perfil, $Info)
    $alvoLog = 'Horário ativo do Windows Update'
    if ($Info.EditionId -like 'Core*') {
        return Write-LogOtimizacao -Sessao $Sessao -Item 'M8' -Alvo $alvoLog -Resultado Pulado -Detalhe 'Windows Home: efeito das políticas do Windows Update não verificado nesta edição.' | Out-Null
    }
    $h = Get-HorarioAtivo -Perfil $Perfil
    if (-not $h) {
        return Write-LogOtimizacao -Sessao $Sessao -Item 'M8' -Alvo $alvoLog -Resultado Pulado -Detalhe 'Defina Opcoes.M8Inicio e Opcoes.M8Fim no perfil.' | Out-Null
    }
    $alvos = [ordered]@{ ActiveHoursStart = $h.Inicio; ActiveHoursEnd = $h.Fim; SetActiveHours = 1 }
    # Política já definida com outro valor (GPO, MDM ou outra ferramenta): não mistura valores, pula o item inteiro.
    $conflito = @(foreach ($n in $alvos.Keys) {
            $v = Get-ValorRegistro -Caminho "$($script:HKLM)\$($script:SubChaveWu)" -Nome $n
            if ($v.Existe -and [string]$v.Valor -ne [string]$alvos[$n]) { "$n=$($v.Valor)" }
        })
    if ($conflito.Count) {
        return Write-LogOtimizacao -Sessao $Sessao -Item 'M8' -Alvo $alvoLog -ValorAnterior ($conflito -join '; ') -Resultado Pulado -Detalhe 'Política já definida com outro valor (GPO, MDM ou outra ferramenta): nada alterado.' | Out-Null
    }
    foreach ($n in $alvos.Keys) {
        Set-ValorRegistro -Sessao $Sessao -Item 'M8' -Raiz $script:HKLM -SubChave $script:SubChaveWu -Nome $n -Valor $alvos[$n] | Out-Null
    }
}

#endregion

#region Reversão de entradas que não são registro

function Get-ManipuladorReversao {
    <# Manipuladores de reversão. Invoke-Reversao passa a entrada e a sessão como argumentos. #>
    @{
        Trim = {
            param($e, $Sessao)
            if ($Sessao.Simular) { return Write-LogOtimizacao -Sessao $Sessao -Item 'M4' -Alvo 'TRIM do NTFS (DisableDeleteNotify)' -ValorNovo $e.Valor -Resultado Simulado }
            Invoke-Fsutil -Argumentos @('behavior', 'set', 'DisableDeleteNotify', [string]$e.Valor)
            $lido = Get-EstadoTrim
            if (-not $lido.Existe -or [int]$lido.Valor -ne [int]$e.Valor) { throw 'DisableDeleteNotify não voltou ao valor original.' }
            Write-LogOtimizacao -Sessao $Sessao -Item 'M4' -Alvo 'TRIM do NTFS (DisableDeleteNotify)' -ValorAnterior 0 -ValorNovo $e.Valor -Resultado Revertido
        }
    }
}

#endregion

#region Execução

function Invoke-Manutencao {
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

    $itens = Get-ItemPerfil -Perfil $p -Prefixo 'M'
    foreach ($id in @($itens | Where-Object { $_ -in 'M5', 'M6', 'M7' })) {
        Write-LogOtimizacao -Sessao $s -Item $id -Resultado Pulado -Detalhe 'Item só de leitura, executado pela Coleta.' | Out-Null
    }
    if (-not @($itens | Where-Object { $_ -in 'M1', 'M2', 'M3', 'M4', 'M8' }).Count) { Write-Warning 'Nenhum item M1 a M4 ou M8 no perfil. Nada a fazer.'; return $s }
    $info = Get-InfoWindows
    $repararM1 = [bool](Get-Opcao $p 'M1Reparar')
    $repararM2 = [bool](Get-Opcao $p 'M2Reparar')
    Write-LogOtimizacao -Sessao $s -Item 'Contexto' -Alvo 'Windows' -ValorNovo "$($info.EditionId) $($info.Build).$($info.UBR)" -Resultado Info -Detalhe "Executado por $env:USERDOMAIN\$env:USERNAME" | Out-Null

    $altera = ($itens -contains 'M4') -or ($itens -contains 'M8') -or (($itens -contains 'M1') -and $repararM1) -or (($itens -contains 'M2') -and $repararM2)
    if ($altera -and -not $Simular) {
        try {
            $rp = New-PontoRestauracao -Descricao "Otimizacao $($script:NomeScript) $($p.Cliente)"
            Write-LogOtimizacao -Sessao $s -Item 'Backup' -Alvo 'Ponto de restauração' -ValorNovo $rp.SequenceNumber -Resultado OK | Out-Null
        }
        catch {
            Write-LogOtimizacao -Sessao $s -Item 'Backup' -Alvo 'Ponto de restauração' -Resultado Falha -Detalhe $_.Exception.Message | Out-Null
            throw "Backup falhou: nada foi alterado. $($_.Exception.Message)"
        }
    }

    if ($itens -contains 'M4') { Invoke-ItemOtimizacao -Sessao $s -Id 'M4' -Acao { Invoke-M4 -Sessao $s } }
    if ($itens -contains 'M8') { Invoke-ItemOtimizacao -Sessao $s -Id 'M8' -Acao { Invoke-M8 -Sessao $s -Perfil $p -Info $info } }
    if ($itens -contains 'M3') { Invoke-ItemOtimizacao -Sessao $s -Id 'M3' -Acao { Invoke-M3 -Sessao $s } }
    if ($itens -contains 'M1') { Invoke-ItemOtimizacao -Sessao $s -Id 'M1' -Acao { Invoke-M1 -Sessao $s -Reparar $repararM1 } }
    if ($itens -contains 'M2') { Invoke-ItemOtimizacao -Sessao $s -Id 'M2' -Acao { Invoke-M2 -Sessao $s -Reparar $repararM2 } }
    $s
}

# Permite carregar as funções com dot-source (testes) sem executar.
if ($MyInvocation.InvocationName -ne '.') {
    $s = Invoke-Manutencao -Perfil $Perfil -Revert:$Revert -Sessao $Sessao -PermitirReinicializacaoPendente:$PermitirReinicializacaoPendente -Simular:([bool]$WhatIfPreference)
    if ($s) {
        $s.Linhas | Format-Table -Property Item, Alvo, ValorAnterior, ValorNovo, Resultado, Detalhe -AutoSize -Wrap | Out-String -Width 220
        Get-ResumoSessao -Sessao $s | Format-Table -AutoSize | Out-String
        if ($s.Pasta) { "Sessão: $($s.Pasta)" }
        if (@($s.Linhas | Where-Object Resultado -eq 'Falha').Count) { exit 1 }
    }
}

#endregion
