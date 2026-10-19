<#
.SYNOPSIS
    Limpeza de armazenamento (itens L1 a L9 do catálogo) conforme o perfil do cliente.

.DESCRIPTION
    Aplica somente os itens L* listados em Aplicar no perfil e não listados em Pular.
      L1  Temporários do Windows (%windir%\Temp) mais antigos que -IdadeMinimaDias.
      L2  Temporários de todos os perfis de usuário (AppData\Local\Temp) mais antigos que -IdadeMinimaDias.
      L3  Cache do Chrome e do Edge (somente a pasta Cache de cada perfil do navegador). Pulado se o navegador estiver aberto.
          Nunca toca em cookies, senhas, histórico ou sessões.
      L4  Cache de download do Windows Update (SoftwareDistribution\Download). Para wuauserv e BITS durante a limpeza
          e os reinicia se estavam em execução. Não toca em DataStore nem em configurações do Windows Update.
      L5  Lixeira de todos os usuários, em todas as unidades fixas.
      L6  Windows.old, pela Limpeza de Disco (cleanmgr, categoria Previous Installations).
      L7  Limpeza de componentes: Dism /Online /Cleanup-Image /StartComponentCleanup (nunca /ResetBase).
      L8  HDD: desfragmenta. SSD: garante a tarefa de otimização agendada do Windows (TRIM) habilitada. Tipo de mídia
          detectado por Get-PhysicalDisk; mídia não identificada é pulada.
      L9  Sensor de Armazenamento por política: ligado, limpando temporários; Lixeira e Downloads nunca.

    Antes de alterar: pré-checagens, ponto de restauração confirmado e backup dos valores originais em
    %ProgramData%\Otimizacao\<Cliente>\<data>-Limpeza (estado-original.json e log.csv).
    A varredura não segue pontos de junção nem links simbólicos e ignora arquivos em uso.

.PARAMETER Perfil
    Arquivo .psd1 do cliente.

.PARAMETER IdadeMinimaDias
    Idade mínima (última gravação ou criação) dos temporários em L1 e L2. Padrão: 7.

.PARAMETER Revert
    Reverte todas as sessões de aplicação ainda não revertidas, da mais recente para a mais antiga (ou só a indicada
    em -Sessao): restaura L8 (estado da tarefa) e L9 (políticas).

.PARAMETER Sessao
    Pasta da sessão a reverter.

.PARAMETER PermitirReinicializacaoPendente
    Não bloqueia a execução quando há reinicialização pendente.

.EXAMPLE
    .\Limpeza.ps1 -Perfil .\perfis\ClienteX.psd1 -WhatIf

.EXAMPLE
    .\Limpeza.ps1 -Perfil .\perfis\ClienteX.psd1

.EXAMPLE
    .\Limpeza.ps1 -Perfil .\perfis\ClienteX.psd1 -Revert

.NOTES
    O que se perde: L1 a L5 apagam arquivos (temporários, caches, Lixeira) sem possibilidade de reversão.
    L6 remove a opção de voltar à versão anterior do Windows. L7 impede desinstalar atualizações já substituídas.
    L3 deixa as primeiras páginas mais lentas até o cache se refazer. L4 faz o Windows Update baixar de novo o que estiver pendente.
    Reversão: -Revert restaura L8 e L9. L1 a L7 não são reversíveis por natureza; o ponto de restauração criado
    antes não recupera arquivos de usuário.
    Na simulação podem aparecer linhas "What if" de módulos do Windows (criação de alias, Remove CimSession): são
    internas desses módulos e não alteram o sistema. O que mudaria é a tabela com Resultado Simulado.
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Aplicar')]
param(
    [Parameter(Mandatory)]
    [string]$Perfil,

    [Parameter(ParameterSetName = 'Aplicar')]
    [ValidateRange(0, 365)]
    [int]$IdadeMinimaDias = 7,

    [Parameter(ParameterSetName = 'Reverter', Mandatory)]
    [switch]$Revert,

    [Parameter(ParameterSetName = 'Reverter')]
    [string]$Sessao,

    [switch]$PermitirReinicializacaoPendente
)

Import-Module (Join-Path $PSScriptRoot 'Otimizacao.Comum.psm1') -Force

$script:NomeScript = 'Limpeza'
$script:FlagCleanmgr = 'StateFlags6464'

#region Varredura e remoção de arquivos

function Get-ArquivoLimpeza {
    <# Arquivos sob Pasta, sem seguir pontos de junção nem links simbólicos. #>
    param([Parameter(Mandatory)][string]$Pasta, [int]$IdadeMinimaDias = 0, [string[]]$Excluir = @())
    $raiz = Get-Item -LiteralPath $Pasta -Force -ErrorAction SilentlyContinue
    if (-not $raiz -or -not $raiz.PSIsContainer -or ($raiz.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return }
    $limite = (Get-Date).AddDays(-$IdadeMinimaDias)
    $pilha = New-Object System.Collections.Generic.Stack[IO.DirectoryInfo]
    $pilha.Push($raiz)
    while ($pilha.Count) {
        $dir = $pilha.Pop()
        try { $itens = $dir.GetFileSystemInfos() } catch { continue }
        foreach ($i in $itens) {
            if ($i.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($i -is [IO.DirectoryInfo]) { $pilha.Push($i); continue }
            if ($Excluir -contains $i.Name) { continue }
            if ($IdadeMinimaDias -gt 0) {
                $data = if ($i.LastWriteTime -gt $i.CreationTime) { $i.LastWriteTime } else { $i.CreationTime }
                if ($data -gt $limite) { continue }
            }
            $i
        }
    }
}

function Get-SubpastaLimpeza {
    <# Subpastas de Pasta (sem a raiz), pai antes dos filhos, sem seguir reparse points. #>
    param([Parameter(Mandatory)][string]$Pasta)
    $raiz = Get-Item -LiteralPath $Pasta -Force -ErrorAction SilentlyContinue
    if (-not $raiz -or ($raiz.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return }
    $pilha = New-Object System.Collections.Generic.Stack[IO.DirectoryInfo]
    $pilha.Push($raiz)
    while ($pilha.Count) {
        $dir = $pilha.Pop()
        try { $subs = $dir.GetDirectories() } catch { continue }
        foreach ($s in $subs) {
            if ($s.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            $s; $pilha.Push($s)
        }
    }
}

function Remove-PastaVazia {
    <# Remove as pastas vazias da lista (nunca a raiz), de baixo para cima. A idade vem de Datas, gravadas antes
       de apagar os arquivos, porque apagar um arquivo atualiza a data da pasta. Só é chamada fora da simulação. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Chamada apenas fora da simulação; -WhatIf é tratado pela sessão.')]
    param([Parameter(Mandatory)][AllowEmptyCollection()][IO.DirectoryInfo[]]$Pastas, [hashtable]$Datas = @{}, [int]$IdadeMinimaDias = 0)
    $limite = (Get-Date).AddDays(-$IdadeMinimaDias)
    for ($i = $Pastas.Count - 1; $i -ge 0; $i--) {
        $d = $Pastas[$i]
        try {
            $d.Refresh()
            if (-not $d.Exists) { continue }
            $data = if ($Datas.ContainsKey($d.FullName)) { $Datas[$d.FullName] } else { $d.LastWriteTime }
            if ($IdadeMinimaDias -gt 0 -and $data -gt $limite) { continue }
            if (-not @($d.GetFileSystemInfos()).Count) { $d.Delete() }
        }
        catch { Write-Verbose "Pasta mantida: $($d.FullName)" }
    }
}

function Format-Tamanho {
    param([long]$Bytes)
    if ($Bytes -lt 1MB) { '{0} KB' -f [math]::Round($Bytes / 1KB, 1) } else { '{0} MB' -f [math]::Round($Bytes / 1MB, 1) }
}

function Remove-ArquivoLimpeza {
    <# Remove os arquivos elegíveis de uma pasta, registrando quantidade e tamanho. Em simulação só lista. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Simulação controlada por Sessao.Simular, derivado de -WhatIf.')]
    param(
        [Parameter(Mandatory)]$Sessao,
        [Parameter(Mandatory)][string]$Item,
        [Parameter(Mandatory)][string]$Pasta,
        [int]$IdadeMinimaDias = 0,
        [string[]]$Excluir = @(),
        [switch]$RemoverPastas
    )
    if (-not (Test-Path -LiteralPath $Pasta)) {
        return Write-LogOtimizacao -Sessao $Sessao -Item $Item -Alvo $Pasta -Resultado JaAplicado -Detalhe 'Pasta inexistente.'
    }
    $arquivos = @(Get-ArquivoLimpeza -Pasta $Pasta -IdadeMinimaDias $IdadeMinimaDias -Excluir $Excluir)
    $total = [long]($arquivos | Measure-Object -Property Length -Sum).Sum
    $antes = '{0} arquivos, {1}' -f $arquivos.Count, (Format-Tamanho $total)

    if ($Sessao.Simular) {
        return Write-LogOtimizacao -Sessao $Sessao -Item $Item -Alvo $Pasta -ValorAnterior $antes -ValorNovo 'removidos' -Resultado Simulado
    }
    $pastas = @(); $datas = @{}
    if ($RemoverPastas) {
        $pastas = @(Get-SubpastaLimpeza -Pasta $Pasta)
        foreach ($d in $pastas) { $datas[$d.FullName] = $d.LastWriteTime }
    }
    if (-not $arquivos.Count) {
        if ($RemoverPastas) { Remove-PastaVazia -Pastas $pastas -Datas $datas -IdadeMinimaDias $IdadeMinimaDias }
        return Write-LogOtimizacao -Sessao $Sessao -Item $Item -Alvo $Pasta -ValorAnterior $antes -Resultado JaAplicado -Detalhe 'Nada elegível.'
    }
    $ok = 0; $bytes = 0L; $falhas = 0
    foreach ($a in $arquivos) {
        try {
            $tamanho = $a.Length
            if ($a.IsReadOnly) { $a.IsReadOnly = $false }
            $a.Delete()
            $ok++; $bytes += $tamanho
        }
        catch { $falhas++ }
    }
    $script:BytesRemovidos += $bytes
    if ($RemoverPastas) { Remove-PastaVazia -Pastas $pastas -Datas $datas -IdadeMinimaDias $IdadeMinimaDias }
    $novo = 'removidos {0} arquivos, {1}' -f $ok, (Format-Tamanho $bytes)
    $detalhe = if ($falhas) { "$falhas em uso ou sem permissão (mantidos)." } else { $null }
    $resultado = if ($ok) { 'OK' } else { 'Pulado' }
    Write-LogOtimizacao -Sessao $Sessao -Item $Item -Alvo $Pasta -ValorAnterior $antes -ValorNovo $novo -Resultado $resultado -Detalhe $detalhe
}

function Get-PastaPerfilUsuario {
    <# Pastas de perfil dos usuários locais e de domínio (SIDs S-1-5-21-*) que existem no disco. #>
    Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' |
        Where-Object { $_.PSChildName -like 'S-1-5-21-*' } |
        ForEach-Object { $_.GetValue('ProfileImagePath') } |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) }
}

function Get-UnidadeFixa {
    Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' } | ForEach-Object { [string]$_.DriveLetter }
}

#endregion

#region Itens do catálogo

function Invoke-L1 {
    param($Sessao, [int]$IdadeMinimaDias)
    Remove-ArquivoLimpeza -Sessao $Sessao -Item 'L1' -Pasta (Join-Path $env:windir 'Temp') -IdadeMinimaDias $IdadeMinimaDias -RemoverPastas | Out-Null
}

function Invoke-L2 {
    param($Sessao, [int]$IdadeMinimaDias)
    foreach ($perfil in Get-PastaPerfilUsuario) {
        Remove-ArquivoLimpeza -Sessao $Sessao -Item 'L2' -Pasta (Join-Path $perfil 'AppData\Local\Temp') -IdadeMinimaDias $IdadeMinimaDias -RemoverPastas | Out-Null
    }
}

function Invoke-L3 {
    param($Sessao)
    $navegadores = @(
        @{ Nome = 'Chrome'; Processo = 'chrome'; Dados = 'Google\Chrome\User Data' }
        @{ Nome = 'Edge'; Processo = 'msedge'; Dados = 'Microsoft\Edge\User Data' }
    )
    foreach ($n in $navegadores) {
        if (Get-Process -Name $n.Processo -ErrorAction SilentlyContinue) {
            Write-LogOtimizacao -Sessao $Sessao -Item 'L3' -Alvo $n.Nome -Resultado Pulado -Detalhe 'Navegador aberto (inclusive em segundo plano). Feche-o e execute de novo.' | Out-Null
            continue
        }
        foreach ($perfil in Get-PastaPerfilUsuario) {
            $ud = Join-Path $perfil "AppData\Local\$($n.Dados)"
            foreach ($cache in @(Get-Item -Path (Join-Path $ud '*\Cache') -Force -ErrorAction SilentlyContinue)) {
                Remove-ArquivoLimpeza -Sessao $Sessao -Item 'L3' -Pasta $cache.FullName | Out-Null
            }
        }
    }
}

function Invoke-L4 {
    param($Sessao)
    $pasta = Join-Path $env:windir 'SoftwareDistribution\Download'
    $servicos = @(Get-Service -Name wuauserv, bits)
    # Bloco em vez de "ForEach-Object Name": a forma por nome de membro respeita -WhatIf e não executaria na simulação.
    $emExecucao = @($servicos | Where-Object { $_.Status -eq 'Running' } | ForEach-Object { $_.Name })
    if ($Sessao.Simular) {
        Write-LogOtimizacao -Sessao $Sessao -Item 'L4' -Alvo 'wuauserv, bits' -ValorAnterior ($emExecucao -join ', ') -ValorNovo 'parados durante a limpeza e reiniciados' -Resultado Simulado | Out-Null
        Remove-ArquivoLimpeza -Sessao $Sessao -Item 'L4' -Pasta $pasta | Out-Null
        return
    }
    # Sem nada elegível, não interrompe o Windows Update.
    if (-not @(Get-ArquivoLimpeza -Pasta $pasta).Count) {
        return Remove-ArquivoLimpeza -Sessao $Sessao -Item 'L4' -Pasta $pasta | Out-Null
    }
    Stop-Service -Name wuauserv, bits -Force -ErrorAction Stop
    try {
        Remove-ArquivoLimpeza -Sessao $Sessao -Item 'L4' -Pasta $pasta -RemoverPastas | Out-Null
    }
    finally {
        foreach ($s in $emExecucao) { Start-Service -Name $s -ErrorAction SilentlyContinue }
        $naoVoltou = @($emExecucao | Where-Object { (Get-Service -Name $_).Status -ne 'Running' })
        if ($naoVoltou.Count) { throw "Serviço(s) não reiniciado(s): $($naoVoltou -join ', ')." }
        Write-LogOtimizacao -Sessao $Sessao -Item 'L4' -Alvo 'wuauserv, bits' -ValorAnterior ($emExecucao -join ', ') -ValorNovo 'reiniciados' -Resultado Info | Out-Null
    }
}

function Invoke-L5 {
    param($Sessao)
    foreach ($letra in Get-UnidadeFixa) {
        $lixeira = "$($letra):\`$Recycle.Bin"
        foreach ($pasta in @(Get-ChildItem -LiteralPath $lixeira -Directory -Force -ErrorAction SilentlyContinue)) {
            Remove-ArquivoLimpeza -Sessao $Sessao -Item 'L5' -Pasta $pasta.FullName -Excluir 'desktop.ini' -RemoverPastas | Out-Null
        }
    }
}

function Invoke-L6 {
    param($Sessao)
    $pasta = Join-Path $env:SystemDrive 'Windows.old'
    if (-not (Test-Path -LiteralPath $pasta)) {
        return Write-LogOtimizacao -Sessao $Sessao -Item 'L6' -Alvo $pasta -Resultado JaAplicado -Detalhe 'Não existe.' | Out-Null
    }
    $total = [long](Get-ArquivoLimpeza -Pasta $pasta | Measure-Object -Property Length -Sum).Sum
    $antes = Format-Tamanho $total
    if ($Sessao.Simular) {
        return Write-LogOtimizacao -Sessao $Sessao -Item 'L6' -Alvo $pasta -ValorAnterior $antes -ValorNovo 'removido pela Limpeza de Disco' -Resultado Simulado | Out-Null
    }
    $raiz = 'Registry::HKEY_LOCAL_MACHINE'
    $base = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
    # Só a categoria Previous Installations pode estar marcada no conjunto 6464.
    $marcadas = @(Get-ChildItem -LiteralPath "$raiz\$base" | Where-Object { $_.PSChildName -ne 'Previous Installations' -and @($_.GetValueNames()) -contains $script:FlagCleanmgr })
    foreach ($k in $marcadas) {
        Set-ValorRegistro -Sessao $Sessao -Item 'L6' -Raiz $raiz -SubChave "$base\$($k.PSChildName)" -Nome $script:FlagCleanmgr -Valor 0 | Out-Null
    }
    Set-ValorRegistro -Sessao $Sessao -Item 'L6' -Raiz $raiz -SubChave "$base\Previous Installations" -Nome $script:FlagCleanmgr -Valor 2 | Out-Null
    $encerrado = $null
    try {
        $proc = Start-Process -FilePath (Join-Path $env:windir 'System32\cleanmgr.exe') -ArgumentList "/sagerun:$($script:FlagCleanmgr.Substring(10))" -PassThru -WindowStyle Hidden
        $encerrado = Wait-Cleanmgr -Processo $proc -Pasta $pasta
    }
    finally {
        $entradas = @($Sessao.Entradas | Where-Object { $_.Item -eq 'L6' -and $_.Nome -eq $script:FlagCleanmgr })
        [array]::Reverse($entradas)
        foreach ($e in $entradas) { Restore-ValorRegistro -Sessao $Sessao -Entrada $e -Raiz $raiz | Out-Null }
    }
    $resta = [long](Get-ArquivoLimpeza -Pasta $pasta | Measure-Object -Property Length -Sum).Sum
    $novo = if (Test-Path -LiteralPath $pasta) { '{0} restantes' -f (Format-Tamanho $resta) } else { 'removido' }
    $resultado = if (Test-Path -LiteralPath $pasta) { 'Falha' } else { 'OK' }
    Write-LogOtimizacao -Sessao $Sessao -Item 'L6' -Alvo $pasta -ValorAnterior $antes -ValorNovo $novo -Resultado $resultado -Detalhe $encerrado | Out-Null
}

function Wait-Cleanmgr {
    <#
        Aguarda o cleanmgr /sagerun. Ele pode não encerrar ao terminar: fica ocioso até haver movimento do mouse e,
        sem sessão interativa, nunca encerra (learn.microsoft.com/en-us/answers/questions/2197296, Windows 10, 11 e
        Server 2016 a 2022). Com a pasta já removida, espera SegundosApos e encerra o processo e os filhos dele.
        Retorna $null se o cleanmgr terminou sozinho, ou o motivo do encerramento.
    #>
    param([Parameter(Mandatory)]$Processo, [Parameter(Mandatory)][string]$Pasta, [int]$SegundosApos = 60, [int]$LimiteMinutos = 120)
    $limite = (Get-Date).AddMinutes($LimiteMinutos)
    $removidaEm = $null
    while (-not $Processo.HasExited -and (Get-Date) -lt $limite) {
        Start-Sleep -Seconds 5
        if (Test-Path -LiteralPath $Pasta) { $removidaEm = $null; continue }
        if (-not $removidaEm) { $removidaEm = Get-Date }
        elseif (((Get-Date) - $removidaEm).TotalSeconds -ge $SegundosApos) { break }
    }
    if ($Processo.HasExited) { return $null }
    $motivo = if (Test-Path -LiteralPath $Pasta) { "cleanmgr encerrado após o limite de $LimiteMinutos min." } else { 'cleanmgr não encerrou sozinho após remover a pasta (falha conhecida do Windows); processo encerrado.' }
    Get-CimInstance Win32_Process -Filter "ParentProcessId=$($Processo.Id)" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Stop-Process -Id $Processo.Id -Force -ErrorAction SilentlyContinue
    $motivo
}

function Invoke-L7 {
    param($Sessao)
    $alvo = 'Dism /Online /Cleanup-Image /StartComponentCleanup'
    if ($Sessao.Simular) {
        return Write-LogOtimizacao -Sessao $Sessao -Item 'L7' -Alvo $alvo -Resultado Simulado -Detalhe 'Tamanho recuperado só é conhecido após a execução (medido pelo espaço livre).' | Out-Null
    }
    $letra = $env:SystemDrive.Substring(0, 1)
    $antes = (Get-Volume -DriveLetter $letra).SizeRemaining
    $p = Start-Process -FilePath (Join-Path $env:windir 'System32\Dism.exe') -ArgumentList '/Online', '/Cleanup-Image', '/StartComponentCleanup', '/NoRestart' -Wait -PassThru -WindowStyle Hidden
    $depois = (Get-Volume -DriveLetter $letra).SizeRemaining
    $ganho = [math]::Round(($depois - $antes) / 1MB, 1)
    # 0 = sucesso; 3010 = sucesso, reinicialização necessária
    if ($p.ExitCode -notin 0, 3010) { throw "DISM terminou com código $($p.ExitCode)." }
    $detalhe = if ($p.ExitCode -eq 3010) { 'Reinicialização necessária para concluir.' } else { $null }
    Write-LogOtimizacao -Sessao $Sessao -Item 'L7' -Alvo $alvo -ValorNovo ('espaço livre {0:+0.0;-0.0;0} MB' -f $ganho) -Resultado OK -Detalhe $detalhe | Out-Null
}

function Get-MidiaUnidade {
    param([string]$Letra)
    $disco = Get-Partition -DriveLetter $Letra -ErrorAction Stop | Get-Disk
    $fisico = Get-PhysicalDisk | Where-Object { $_.DeviceId -eq [string]$disco.Number } | Select-Object -First 1
    if ($fisico) { [string]$fisico.MediaType } else { 'Unspecified' }
}

function Invoke-L8 {
    param($Sessao)
    $temSsd = $false
    foreach ($letra in Get-UnidadeFixa) {
        $midia = Get-MidiaUnidade -Letra $letra
        switch ($midia) {
            'HDD' {
                if ($Sessao.Simular) {
                    Write-LogOtimizacao -Sessao $Sessao -Item 'L8' -Alvo "$($letra): (HDD)" -ValorNovo 'desfragmentar' -Resultado Simulado | Out-Null
                }
                else {
                    Optimize-Volume -DriveLetter $letra -Defrag -ErrorAction Stop
                    Write-LogOtimizacao -Sessao $Sessao -Item 'L8' -Alvo "$($letra): (HDD)" -ValorNovo 'desfragmentado' -Resultado OK | Out-Null
                }
            }
            'SSD' { $temSsd = $true }
            default {
                Write-LogOtimizacao -Sessao $Sessao -Item 'L8' -Alvo "$($letra):" -ValorAnterior $midia -Resultado Pulado -Detalhe 'Tipo de mídia não identificado (comum em VM e RAID): nada feito.' | Out-Null
            }
        }
    }
    if (-not $temSsd) { return }
    $tarefa = Get-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag' -ErrorAction Stop
    $estado = [string]$tarefa.State
    if ($estado -ne 'Disabled') {
        return Write-LogOtimizacao -Sessao $Sessao -Item 'L8' -Alvo 'Tarefa ScheduledDefrag (TRIM)' -ValorAnterior $estado -Resultado JaAplicado | Out-Null
    }
    if ($Sessao.Simular) {
        return Write-LogOtimizacao -Sessao $Sessao -Item 'L8' -Alvo 'Tarefa ScheduledDefrag (TRIM)' -ValorAnterior $estado -ValorNovo 'Ready' -Resultado Simulado | Out-Null
    }
    Add-EstadoOriginal -Sessao $Sessao -Entrada @{ Tipo = 'Tarefa'; Item = 'L8'; Caminho = '\Microsoft\Windows\Defrag\'; Nome = 'ScheduledDefrag'; Estado = $estado }
    Enable-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag' -ErrorAction Stop | Out-Null
    $novo = [string](Get-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag').State
    if ($novo -eq 'Disabled') { throw 'A tarefa ScheduledDefrag continua desabilitada.' }
    Write-LogOtimizacao -Sessao $Sessao -Item 'L8' -Alvo 'Tarefa ScheduledDefrag (TRIM)' -ValorAnterior $estado -ValorNovo $novo -Resultado OK | Out-Null
}

function Invoke-L9 {
    param($Sessao)
    # Políticas do StorageSense.admx. RecycleBin e Downloads 0 = nunca apagar.
    $sub = 'SOFTWARE\Policies\Microsoft\Windows\StorageSense'
    $valores = [ordered]@{
        AllowStorageSenseGlobal                      = 1
        AllowStorageSenseTemporaryFilesCleanup       = 1
        ConfigStorageSenseRecycleBinCleanupThreshold = 0
        ConfigStorageSenseDownloadsCleanupThreshold  = 0
    }
    foreach ($nome in $valores.Keys) {
        Set-ValorRegistro -Sessao $Sessao -Item 'L9' -Raiz 'Registry::HKEY_LOCAL_MACHINE' -SubChave $sub -Nome $nome -Valor $valores[$nome] -PularSeDefinido | Out-Null
    }
}

#endregion

#region Execução

function Invoke-Limpeza {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'IdadeMinimaDias', Justification = 'Usado nos scriptblocks de ação.')]
    param([string]$Perfil, [int]$IdadeMinimaDias, [switch]$Revert, [string]$Sessao, [switch]$PermitirReinicializacaoPendente, [switch]$Simular)

    $p = Import-PerfilCliente -Caminho $Perfil
    $pre = Test-PreCondicao -PermitirReinicializacaoPendente:$PermitirReinicializacaoPendente -EspacoMinimoGB 1
    foreach ($a in $pre.Avisos) { Write-Warning $a }
    if ($pre.Bloqueios.Count) {
        foreach ($b in $pre.Bloqueios) { Write-Warning "BLOQUEIO: $b" }
        if (-not $Simular) { throw 'Execução bloqueada pelas pré-checagens. Nada foi alterado.' }
    }

    # A sessão da reversão tem nome próprio para não ser confundida com uma sessão de aplicação pendente.
    $nomeSessao = if ($Revert) { "$($script:NomeScript)-Reversao" } else { $script:NomeScript }
    $s = New-SessaoOtimizacao -Cliente $p.Cliente -Script $nomeSessao -Simular:$Simular

    if ($Revert) {
        $manipuladores = @{
            Tarefa = {
                param($e, $Sessao)
                if ($Sessao.Simular) {
                    return Write-LogOtimizacao -Sessao $Sessao -Item $e.Item -Alvo "$($e.Caminho)$($e.Nome)" -ValorNovo $e.Estado -Resultado Simulado
                }
                if ($e.Estado -eq 'Disabled') { Disable-ScheduledTask -TaskPath $e.Caminho -TaskName $e.Nome -ErrorAction Stop | Out-Null }
                $atual = [string](Get-ScheduledTask -TaskPath $e.Caminho -TaskName $e.Nome).State
                if (($e.Estado -eq 'Disabled') -ne ($atual -eq 'Disabled')) { throw "Reversão divergente na tarefa $($e.Nome)." }
                Write-LogOtimizacao -Sessao $Sessao -Item $e.Item -Alvo "$($e.Caminho)$($e.Nome)" -ValorNovo $atual -Resultado Revertido
            }
        }
        Invoke-ReversaoPendente -Sessao $s -Cliente $p.Cliente -Script $script:NomeScript -Pasta $Sessao -Manipuladores $manipuladores
    }
    else {
        $itens = Get-ItemPerfil -Perfil $p -Prefixo 'L'
        if (-not $itens.Count) { Write-Warning 'Nenhum item L* no perfil. Nada a fazer.'; return }
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
        $letra = $env:SystemDrive.Substring(0, 1)
        $livreAntes = (Get-Volume -DriveLetter $letra).SizeRemaining
        $script:BytesRemovidos = 0L
        $acoes = [ordered]@{
            L1 = { Invoke-L1 -Sessao $s -IdadeMinimaDias $IdadeMinimaDias }
            L2 = { Invoke-L2 -Sessao $s -IdadeMinimaDias $IdadeMinimaDias }
            L3 = { Invoke-L3 -Sessao $s }
            L4 = { Invoke-L4 -Sessao $s }
            L5 = { Invoke-L5 -Sessao $s }
            L6 = { Invoke-L6 -Sessao $s }
            L7 = { Invoke-L7 -Sessao $s }
            L8 = { Invoke-L8 -Sessao $s }
            L9 = { Invoke-L9 -Sessao $s }
        }
        foreach ($id in $acoes.Keys) {
            if ($itens -contains $id) { Invoke-ItemOtimizacao -Sessao $s -Id $id -Acao $acoes[$id] }
        }
        $variacao = [math]::Round(((Get-Volume -DriveLetter $letra).SizeRemaining - $livreAntes) / 1GB, 2)
        if (-not $Simular) {
            # A variação do espaço livre mistura o que foi removido com o que outros processos gravaram no mesmo período
            # (medido na VM: -1,44 GB com 211 MB removidos, Windows Update e cópia de sombra ativos). Por isso os dois números.
            Write-LogOtimizacao -Sessao $s -Item 'Resumo' -Alvo 'Arquivos removidos (L1 a L5)' -ValorNovo (Format-Tamanho $script:BytesRemovidos) -Resultado Info `
                -Detalhe ("Espaço livre em {0}: variou {1:+0.00;-0.00;0} GB, incluindo o que outros processos gravaram no período (Windows Update, cópia de sombra do ponto de restauração)." -f $letra, $variacao) | Out-Null
        }
    }

    $s
}

# Permite carregar as funções com dot-source (testes) sem executar.
if ($MyInvocation.InvocationName -ne '.') {
    $s = Invoke-Limpeza -Perfil $Perfil -IdadeMinimaDias $IdadeMinimaDias -Revert:$Revert -Sessao $Sessao `
        -PermitirReinicializacaoPendente:$PermitirReinicializacaoPendente -Simular:([bool]$WhatIfPreference)
    if ($s) {
        $s.Linhas | Format-Table -Property Item, Alvo, ValorAnterior, ValorNovo, Resultado, Detalhe -AutoSize -Wrap | Out-String -Width 220
        Get-ResumoSessao -Sessao $s | Format-Table -AutoSize | Out-String
        if ($s.Pasta) { "Sessão: $($s.Pasta)" }
        if (@($s.Linhas | Where-Object Resultado -eq 'Falha').Count) { exit 1 }
    }
}

#endregion
