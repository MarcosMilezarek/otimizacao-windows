# Testes que alteram o sistema: executar SOMENTE na VM de teste (tools\Testar-NaVM.ps1 define OTIMIZACAO_VM=1).
BeforeAll {
    if ($env:OTIMIZACAO_VM -ne '1') { throw 'Manutencao.Tests.ps1 só pode rodar na VM de teste (OTIMIZACAO_VM=1).' }
    # -Perfil obrigatório: valor fictício só para o binding; com dot-source o script não executa.
    . (Join-Path $PSScriptRoot '..\src\Manutencao.ps1') -Perfil 'nao-usado.psd1'
    $script:raizSessoes = Join-Path $env:TEMP ('sessoes-' + [guid]::NewGuid())
    function New-SessaoTeste { New-SessaoOtimizacao -Cliente T -Script Manutencao -Raiz $script:raizSessoes }
    function Invoke-ReversaoTeste {
        param($Aplicada)
        $alvo = Get-SessaoParaReverter -Cliente T -Script Manutencao -Pasta $Aplicada.Pasta -Raiz $script:raizSessoes
        $sr = New-SessaoTeste
        Invoke-Reversao -Sessao $sr -Alvo $alvo -Manipuladores (Get-ManipuladorReversao)
        $sr
    }
    function Get-Linha { param($S, [string]$Item) @($S.Linhas | Where-Object Item -eq $Item) }
    function Get-Falha { param($S) (@($S.Linhas | Where-Object Resultado -eq 'Falha').Detalhe -join '; ') }
}
AfterAll { Remove-Item $script:raizSessoes -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'M4 TRIM' {
    BeforeAll { $script:trimOriginal = Get-EstadoTrim }
    AfterAll {
        $v = if ($script:trimOriginal.Existe) { [string]$script:trimOriginal.Valor } else { '0' }
        & fsutil.exe behavior set DisableDeleteNotify $v | Out-Null
    }

    It 'fsutil grava o valor lido pelo script (DisableDeleteNotification no registro)' {
        & fsutil.exe behavior set DisableDeleteNotify 1 | Out-Null
        [int](Get-EstadoTrim).Valor | Should -Be 1
        & fsutil.exe behavior set DisableDeleteNotify 0 | Out-Null
        [int](Get-EstadoTrim).Valor | Should -Be 0
        Write-Host ('Saída do fsutil na VM: ' + ((& fsutil.exe behavior query DisableDeleteNotify) -join ' | '))
    }

    It 'Sem SSD: pulado e nada executado' {
        Mock Test-TemSsd { $false }
        Mock Invoke-Fsutil { }
        $s = New-SessaoTeste
        Invoke-M4 -Sessao $s
        (Get-Linha $s 'M4').Resultado | Should -Be 'Pulado'
        Should -Invoke Invoke-Fsutil -Times 0
    }

    It 'Com SSD e TRIM desligado: liga, relê, é idempotente e a reversão restaura' {
        Mock Test-TemSsd { $true }
        & fsutil.exe behavior set DisableDeleteNotify 1 | Out-Null
        $s = New-SessaoTeste
        Invoke-M4 -Sessao $s
        (Get-Linha $s 'M4').Resultado | Should -Be 'OK' -Because (Get-Falha $s)
        [int](Get-EstadoTrim).Valor | Should -Be 0

        $s2 = New-SessaoTeste
        Invoke-M4 -Sessao $s2
        (Get-Linha $s2 'M4').Resultado | Should -Be 'JaAplicado'

        $sr = Invoke-ReversaoTeste -Aplicada $s
        Get-Falha $sr | Should -BeNullOrEmpty
        (Get-Linha $sr 'M4').Resultado | Should -Be 'Revertido'
        [int](Get-EstadoTrim).Valor | Should -Be 1
    }

    It 'Simulação não altera' {
        Mock Test-TemSsd { $true }
        & fsutil.exe behavior set DisableDeleteNotify 1 | Out-Null
        $s = New-SessaoOtimizacao -Cliente T -Script Manutencao -Simular
        Invoke-M4 -Sessao $s
        (Get-Linha $s 'M4').Resultado | Should -Be 'Simulado'
        [int](Get-EstadoTrim).Valor | Should -Be 1
    }

    It 'Reversão simulada não executa fsutil' {
        Mock Invoke-Fsutil { }
        $sr = New-SessaoOtimizacao -Cliente T -Script Manutencao -Simular
        $alvo = [pscustomobject]@{ Pasta = $TestDrive; Entradas = @([pscustomobject]@{ Tipo = 'Trim'; Item = 'M4'; Valor = 1 }) }
        Invoke-Reversao -Sessao $sr -Alvo $alvo -Manipuladores (Get-ManipuladorReversao)
        Should -Invoke Invoke-Fsutil -Times 0
        (Get-Linha $sr 'M4').Resultado | Should -Be 'Simulado'
    }
}

Describe 'M8 horário ativo' {
    BeforeAll {
        $script:chaveWu = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
        $script:info = Get-InfoWindows
        function New-PerfilM8 { param($Inicio, $Fim) [pscustomobject]@{ Opcoes = @{ M8Inicio = $Inicio; M8Fim = $Fim } } }
        function Get-ValorWu { param([string]$Nome) Get-ValorRegistro -Caminho $script:chaveWu -Nome $Nome }
    }

    It 'Aplica 7 h a 19 h, relê, é idempotente e a reversão remove valores e chaves criadas' {
        $chaveExistia = Test-Path $script:chaveWu
        $s = New-SessaoTeste
        Invoke-M8 -Sessao $s -Perfil (New-PerfilM8 7 19) -Info $script:info
        Get-Falha $s | Should -BeNullOrEmpty
        @(Get-Linha $s 'M8' | Where-Object Resultado -eq 'OK').Count | Should -Be 3
        (Get-ValorWu 'ActiveHoursStart').Valor | Should -Be 7
        (Get-ValorWu 'ActiveHoursEnd').Valor | Should -Be 19
        (Get-ValorWu 'SetActiveHours').Valor | Should -Be 1
        (Get-ValorWu 'SetActiveHours').Tipo | Should -Be 'DWord'

        $s2 = New-SessaoTeste
        Invoke-M8 -Sessao $s2 -Perfil (New-PerfilM8 7 19) -Info $script:info
        @(Get-Linha $s2 'M8' | Where-Object Resultado -ne 'JaAplicado').Count | Should -Be 0

        $sr = Invoke-ReversaoTeste -Aplicada $s
        Get-Falha $sr | Should -BeNullOrEmpty
        foreach ($n in 'ActiveHoursStart', 'ActiveHoursEnd', 'SetActiveHours') { (Get-ValorWu $n).Existe | Should -BeFalse }
        Test-Path $script:chaveWu | Should -Be $chaveExistia
    }

    It 'Política já definida com outro valor: pula o item inteiro sem gravar' {
        $chaveExistia = Test-Path $script:chaveWu
        New-Item $script:chaveWu -Force | Out-Null
        New-ItemProperty $script:chaveWu -Name ActiveHoursStart -Value 5 -PropertyType DWord -Force | Out-Null
        try {
            $s = New-SessaoTeste
            Invoke-M8 -Sessao $s -Perfil (New-PerfilM8 7 19) -Info $script:info
            $l = @(Get-Linha $s 'M8')
            $l.Count | Should -Be 1
            $l[0].Resultado | Should -Be 'Pulado'
            $l[0].ValorAnterior | Should -Be 'ActiveHoursStart=5'
            (Get-ValorWu 'ActiveHoursEnd').Existe | Should -BeFalse
            (Get-ValorWu 'SetActiveHours').Existe | Should -BeFalse
        }
        finally {
            Remove-ItemProperty $script:chaveWu -Name ActiveHoursStart -ErrorAction SilentlyContinue
            if (-not $chaveExistia) { Remove-Item $script:chaveWu -ErrorAction SilentlyContinue }
        }
    }

    It 'Windows Home: pulado' {
        $s = New-SessaoTeste
        Invoke-M8 -Sessao $s -Perfil (New-PerfilM8 7 19) -Info ([pscustomobject]@{ EditionId = 'Core' })
        (Get-Linha $s 'M8').Resultado | Should -Be 'Pulado'
        (Get-ValorWu 'SetActiveHours').Existe | Should -BeFalse
    }

    It 'Sem horas no perfil: pulado' {
        $s = New-SessaoTeste
        Invoke-M8 -Sessao $s -Perfil ([pscustomobject]@{ Opcoes = @{} }) -Info $script:info
        (Get-Linha $s 'M8').Detalhe | Should -BeLike '*M8Inicio*'
    }

    It 'Horas <Inicio> a <Fim>: <Esperado>' -ForEach @(
        @{ Inicio = 6; Fim = 2; Esperado = 'recusa (20 h)' }
        @{ Inicio = 8; Fim = 8; Esperado = 'recusa (0 h)' }
        @{ Inicio = 25; Fim = 3; Esperado = 'recusa (hora inválida)' }
        @{ Inicio = 'oito'; Fim = 17; Esperado = 'recusa (hora inválida)' }
        @{ Inicio = 22; Fim = 4; Esperado = 'aceita (6 h, passa da meia-noite)' }
        @{ Inicio = 6; Fim = 0; Esperado = 'aceita (18 h)' }
    ) {
        if ($Esperado -like 'aceita*') { (Get-HorarioAtivo -Perfil (New-PerfilM8 $Inicio $Fim)).Inicio | Should -Be $Inicio }
        else { { Get-HorarioAtivo -Perfil (New-PerfilM8 $Inicio $Fim) } | Should -Throw }
    }
}

Describe 'M3 sistema de arquivos' {
    It 'Verificação real dos volumes da VM: sem erros' {
        $s = New-SessaoTeste
        Invoke-M3 -Sessao $s
        Get-Falha $s | Should -BeNullOrEmpty
        $c = Get-Linha $s 'M3' | Where-Object Alvo -like 'C:*'
        $c.Resultado | Should -Be 'JaAplicado'
        Write-Host "Repair-Volume C: na VM: $($c.ValorAnterior)"
    }

    It 'Status <Status> -> <Resultado>' -ForEach @(
        @{ Status = 'ScanNoErrorsFound'; Resultado = 'JaAplicado'; Atencao = $false }
        @{ Status = 4; Resultado = 'JaAplicado'; Atencao = $false }
        @{ Status = 'ScanErrorsFoundAndFixedOnline'; Resultado = 'Info'; Atencao = $false }
        @{ Status = 'ScanErrorsFoundNeedSpotFix'; Resultado = 'Info'; Atencao = $true }
        @{ Status = 7; Resultado = 'Info'; Atencao = $true }
        @{ Status = 'NeedOfflineScanAndFix'; Resultado = 'Info'; Atencao = $true }
        @{ Status = 'ScanNeedsRetry'; Resultado = 'Falha'; Atencao = $false }
    ) {
        Set-Content -LiteralPath (Join-Path $TestDrive 'status.txt') -Value $Status
        Mock Get-VolumeVerificavel { 'C' }
        Mock Repair-Volume { $v = Get-Content -LiteralPath (Join-Path $TestDrive 'status.txt'); if ($v -match '^\d+$') { [uint32]$v } else { $v } }
        $s = New-SessaoTeste
        Invoke-M3 -Sessao $s 3>$null
        $l = @(Get-Linha $s 'M3')
        $l.Count | Should -Be 1
        $l[0].Resultado | Should -Be $Resultado
        ($l[0].Detalhe -like 'ATENÇÃO*') | Should -Be $Atencao
    }

    It 'Falha num volume não interrompe os demais' {
        Mock Get-VolumeVerificavel { 'C', 'D' }
        Mock Repair-Volume { if ([string]$DriveLetter -eq 'C') { throw 'erro simulado' } 'ScanNoErrorsFound' }
        $s = New-SessaoTeste
        Invoke-M3 -Sessao $s 3>$null
        @(Get-Linha $s 'M3' | Where-Object Resultado -eq 'Falha').Count | Should -Be 1
        (Get-Linha $s 'M3' | Where-Object Alvo -like 'D:*').Resultado | Should -Be 'JaAplicado'
    }

    It 'Simulação não executa Repair-Volume' {
        Mock Repair-Volume { }
        $s = New-SessaoOtimizacao -Cliente T -Script Manutencao -Simular
        Invoke-M3 -Sessao $s
        Should -Invoke Repair-Volume -Times 0
        @(Get-Linha $s 'M3' | Where-Object Resultado -ne 'Simulado').Count | Should -Be 0
    }
}

Describe 'M1 imagem do Windows' {
    It 'Verificação real (ScanHealth): imagem íntegra na VM' {
        $s = New-SessaoTeste
        Invoke-M1 -Sessao $s -Reparar $false
        Get-Falha $s | Should -BeNullOrEmpty
        $l = Get-Linha $s 'M1'
        $l.Resultado | Should -Be 'JaAplicado'
        $l.ValorAnterior | Should -Be 'Healthy'
    }

    It 'Reparável sem aprovação: achado e nenhum reparo' {
        Mock Get-SaudeImagem { 'Repairable' }
        Mock Repair-WindowsImage { }
        $s = New-SessaoTeste
        Invoke-M1 -Sessao $s -Reparar $false 3>$null
        (Get-Linha $s 'M1').Detalhe | Should -BeLike 'ATENÇÃO*M1Reparar*'
        Should -Invoke Repair-WindowsImage -Times 0
    }

    It 'Reparável com aprovação: RestoreHealth sem reiniciar e nova verificação' {
        $marca = Join-Path $TestDrive 'reparado-m1'
        Mock Get-SaudeImagem { if (Test-Path -LiteralPath (Join-Path $TestDrive 'reparado-m1')) { 'Healthy' } else { 'Repairable' } }
        Mock Repair-WindowsImage { New-Item -ItemType File (Join-Path $TestDrive 'reparado-m1') | Out-Null; [pscustomobject]@{ RestartNeeded = $true } }
        $s = New-SessaoTeste
        Invoke-M1 -Sessao $s -Reparar $true
        $l = Get-Linha $s 'M1'
        $l.Resultado | Should -Be 'OK'
        $l.ValorNovo | Should -Be 'Healthy'
        $l.Detalhe | Should -BeLike '*Reinicialização*'
        Should -Invoke Repair-WindowsImage -Times 1 -ParameterFilter { $RestoreHealth -and $Online -and $NoRestart }
        Test-Path $marca | Should -BeTrue
    }

    It 'Reparo sem efeito: erro' {
        Mock Get-SaudeImagem { 'Repairable' }
        Mock Repair-WindowsImage { }
        { Invoke-M1 -Sessao (New-SessaoTeste) -Reparar $true } | Should -Throw '*continua Repairable*'
    }

    It 'Não reparável: achado com orientação' {
        Mock Get-SaudeImagem { 'NonRepairable' }
        $s = New-SessaoTeste
        Invoke-M1 -Sessao $s -Reparar $true 3>$null
        (Get-Linha $s 'M1').Detalhe | Should -BeLike 'ATENÇÃO*in-place*'
    }

    It 'Simulação não executa o DISM' {
        Mock Repair-WindowsImage { }
        $s = New-SessaoOtimizacao -Cliente T -Script Manutencao -Simular
        Invoke-M1 -Sessao $s -Reparar $true
        Should -Invoke Repair-WindowsImage -Times 0
        (Get-Linha $s 'M1').Resultado | Should -Be 'Simulado'
    }
}

Describe 'M2 arquivos de sistema' {
    It 'Get-ResultadoSfc classifica as entradas do artigo da Microsoft' {
        $limpo = @(
            '2026-10-09 10:00:01, Info                  CSI    00000006 [SR] Verifying 100 (0x00000064) components'
            '2026-10-09 10:00:01, Info                  CSI    00000007 [SR] Beginning Verify and Repair transaction'
            '2026-10-09 10:00:02, Info                  CSI    00000009 [SR] Verify complete'
        )
        $r = Get-ResultadoSfc -Linhas $limpo
        $r.Concluido | Should -BeTrue
        $r.Problemas | Should -Be 0

        $sujo = $limpo + @(
            '2026-10-09 10:00:03, Info                  CSI    00000008 [SR] Repairing corrupted file [ml:520{260},l:36{18}]"??\C:\Windows\inf"[l:18{9}]"netnb.inf" from store'
            '2026-10-09 10:00:04, Info                  CSI    0000000b [SR] Cannot repair member file [l:14{7}]"url.dll" of Microsoft-Windows-IE-WinsockAutodialStub'
        )
        $r = Get-ResultadoSfc -Linhas $sujo
        $r.Problemas | Should -Be 2
        $r.NaoReparaveis | Should -Be 1

        (Get-ResultadoSfc -Linhas @()).Concluido | Should -BeFalse
    }

    It 'Get-EntradaSr lê só a execução atual, com o log aberto para escrita por outro processo' {
        $pasta = New-Item -ItemType Directory (Join-Path $TestDrive 'CBS') -Force
        $desde = (Get-Date).AddMinutes(-5)
        $h = { param($Minutos) $desde.AddMinutes($Minutos).ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) }
        $log = Join-Path $pasta.FullName 'CBS.log'
        @(
            "$(& $h -1), Info                  CSI    00000001 [SR] Verify complete"
            "$(& $h 1), Info                  CBS    Linha sem tag"
            "$(& $h 2), Info                  CSI    00000002 [SR] Verify complete"
        ) | Set-Content -LiteralPath $log -Encoding UTF8
        $antigo = Join-Path $pasta.FullName 'CbsPersist_20260101000000.log'
        "$(& $h 3), Info CSI 00000003 [SR] Repairing corrupted file x from store" | Set-Content -LiteralPath $antigo -Encoding UTF8
        (Get-Item $antigo).LastWriteTime = $desde.AddDays(-1)
        # Medido na VM: com o TrustedInstaller segurando o CBS.log, a data do arquivo fica para trás do conteúdo.
        (Get-Item $log).LastWriteTime = $desde.AddDays(-1)
        $escrita = [IO.File]::Open($log, 'Open', 'ReadWrite', 'ReadWrite')
        try { $l = @(Get-EntradaSr -Desde $desde -Pasta $pasta.FullName) }
        finally { $escrita.Dispose() }
        $l.Count | Should -Be 1
        $l[0] | Should -BeLike '*00000002*'
    }

    It 'Verificação real (sfc /verifyonly): sem violações, lida do CBS.log da VM em pt-BR' {
        $s = New-SessaoTeste
        Invoke-M2 -Sessao $s -Reparar $false
        Get-Falha $s | Should -BeNullOrEmpty
        (Get-Linha $s 'M2').Resultado | Should -Be 'JaAplicado'
        Write-Host ('Primeira linha [SR] da execução: ' + (Get-EntradaSr -Desde (Get-Date).AddMinutes(-30) | Select-Object -First 1))
    }

    It 'Violações sem aprovação: achado e sem scannow' {
        Mock Invoke-Sfc -ParameterFilter { $Modo -eq '/verifyonly' } { [pscustomobject]@{ Concluido = $true; Problemas = 2; NaoReparaveis = 0; CodigoSaida = 0 } }
        Mock Invoke-Sfc -ParameterFilter { $Modo -eq '/scannow' } { }
        $s = New-SessaoTeste
        Invoke-M2 -Sessao $s -Reparar $false 3>$null
        (Get-Linha $s 'M2').Detalhe | Should -BeLike 'ATENÇÃO*M2Reparar*'
        Should -Invoke Invoke-Sfc -Times 0 -ParameterFilter { $Modo -eq '/scannow' }
    }

    It 'Violações com aprovação: scannow e nova verificação limpa' {
        Mock Invoke-Sfc -ParameterFilter { $Modo -eq '/scannow' } { New-Item -ItemType File (Join-Path $TestDrive 'reparado-m2') -Force | Out-Null }
        Mock Invoke-Sfc -ParameterFilter { $Modo -eq '/verifyonly' } {
            $p = if (Test-Path -LiteralPath (Join-Path $TestDrive 'reparado-m2')) { 0 } else { 3 }
            [pscustomobject]@{ Concluido = $true; Problemas = $p; NaoReparaveis = 0; CodigoSaida = 0 }
        }
        $s = New-SessaoTeste
        Invoke-M2 -Sessao $s -Reparar $true
        $l = Get-Linha $s 'M2'
        $l.Resultado | Should -Be 'OK'
        $l.ValorNovo | Should -Be 'sem violações'
        Should -Invoke Invoke-Sfc -Times 1 -ParameterFilter { $Modo -eq '/scannow' }
        Should -Invoke Invoke-Sfc -Times 2 -ParameterFilter { $Modo -eq '/verifyonly' }
    }

    It 'Violações que persistem após scannow: erro' {
        Mock Invoke-Sfc -ParameterFilter { $Modo -eq '/scannow' } { }
        Mock Invoke-Sfc -ParameterFilter { $Modo -eq '/verifyonly' } { [pscustomobject]@{ Concluido = $true; Problemas = 1; NaoReparaveis = 1; CodigoSaida = 0 } }
        { Invoke-M2 -Sessao (New-SessaoTeste) -Reparar $true } | Should -Throw '*continuam com violação*'
    }

    It 'Sem conclusão registrada no CBS.log: erro' {
        Mock Invoke-Sfc { [pscustomobject]@{ Concluido = $false; Problemas = 0; NaoReparaveis = 0; CodigoSaida = 1 } }
        { Invoke-M2 -Sessao (New-SessaoTeste) -Reparar $false } | Should -Throw '*sem conclusão*'
    }

    It 'Simulação não executa o sfc' {
        Mock Invoke-Sfc { }
        $s = New-SessaoOtimizacao -Cliente T -Script Manutencao -Simular
        Invoke-M2 -Sessao $s -Reparar $true
        Should -Invoke Invoke-Sfc -Times 0
        (Get-Linha $s 'M2').Resultado | Should -Be 'Simulado'
    }
}

Describe 'Invoke-Manutencao' {
    BeforeAll {
        function New-PerfilTeste {
            param([string]$Conteudo)
            $arq = Join-Path $TestDrive ('perfil-{0}.psd1' -f [guid]::NewGuid())
            $Conteudo | Out-File $arq -Encoding UTF8
            $arq
        }
        $script:ordem = Join-Path $TestDrive 'ordem.txt'
    }
    BeforeEach {
        Remove-Item $script:ordem -ErrorAction SilentlyContinue
        Mock Test-PreCondicao { [pscustomobject]@{ Bloqueios = @(); Avisos = @() } }
        Mock Invoke-M1 { Add-Content (Join-Path $TestDrive 'ordem.txt') 'M1' }
        Mock Invoke-M2 { Add-Content (Join-Path $TestDrive 'ordem.txt') 'M2' }
        Mock Invoke-M3 { Add-Content (Join-Path $TestDrive 'ordem.txt') 'M3' }
        Mock Invoke-M4 { Add-Content (Join-Path $TestDrive 'ordem.txt') 'M4' }
        Mock Invoke-M8 { Add-Content (Join-Path $TestDrive 'ordem.txt') 'M8' }
    }

    It 'Falha no ponto de restauração com item que altera: nada é executado' {
        Mock New-PontoRestauracao { throw 'Proteção do Sistema desativada' }
        $p = New-PerfilTeste "@{ Cliente = 'TesteVM'; Aplicar = @('M3','M4','M8') }"
        { Invoke-Manutencao -Perfil $p } | Should -Throw '*Backup falhou*'
        Test-Path $script:ordem | Should -BeFalse
    }

    It 'Só verificações (sem reparo aprovado): não cria ponto de restauração' {
        Mock New-PontoRestauracao { throw 'não deveria ser chamado' }
        $p = New-PerfilTeste "@{ Cliente = 'TesteVM'; Aplicar = @('M1','M2','M3') }"
        Invoke-Manutencao -Perfil $p | Out-Null
        Should -Invoke New-PontoRestauracao -Times 0
        Get-Content $script:ordem | Should -Be @('M3', 'M1', 'M2')
    }

    It 'Reparo aprovado exige ponto de restauração' {
        Mock New-PontoRestauracao { [pscustomobject]@{ SequenceNumber = 7 } }
        $p = New-PerfilTeste "@{ Cliente = 'TesteVM'; Aplicar = @('M1'); Opcoes = @{ M1Reparar = `$true } }"
        Invoke-Manutencao -Perfil $p | Out-Null
        Should -Invoke New-PontoRestauracao -Times 1
    }

    It 'Ordem M4, M8, M3, M1, M2 (DISM antes do SFC) e M5 a M7 pulados' {
        Mock New-PontoRestauracao { [pscustomobject]@{ SequenceNumber = 8 } }
        $p = New-PerfilTeste "@{ Cliente = 'TesteVM'; Aplicar = @('M2','M1','M5','M3','M6','M8','M7','M4') }"
        $s = Invoke-Manutencao -Perfil $p
        Get-Content $script:ordem | Should -Be @('M4', 'M8', 'M3', 'M1', 'M2')
        foreach ($id in 'M5', 'M6', 'M7') { (Get-Linha $s $id).Detalhe | Should -BeLike '*Coleta*' }
    }

    It 'Simulação não cria ponto de restauração' {
        Mock New-PontoRestauracao { throw 'não deveria ser chamado' }
        $p = New-PerfilTeste "@{ Cliente = 'TesteVM'; Aplicar = @('M4','M8') }"
        Invoke-Manutencao -Perfil $p -Simular | Out-Null
        Should -Invoke New-PontoRestauracao -Times 0
    }
}
