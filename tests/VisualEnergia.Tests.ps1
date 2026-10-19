# Testes que alteram o sistema: executar SOMENTE na VM de teste (tools\Testar-NaVM.ps1 define OTIMIZACAO_VM=1).
BeforeAll {
    if ($env:OTIMIZACAO_VM -ne '1') { throw 'VisualEnergia.Tests.ps1 só pode rodar na VM de teste (OTIMIZACAO_VM=1).' }
    # -Perfil obrigatório: valor fictício só para o binding; com dot-source o script não executa.
    . (Join-Path $PSScriptRoot '..\src\VisualEnergia.ps1') -Perfil 'nao-usado.psd1'
    $script:raizSessoes = Join-Path $env:TEMP ('sessoes-' + [guid]::NewGuid())
    function New-SessaoTeste { New-SessaoOtimizacao -Cliente T -Script VisualEnergia -Raiz $script:raizSessoes }
    function Invoke-ReversaoTeste {
        # Parâmetro não se chama $Sessao: um nome igual mascarou, por escopo dinâmico, manipuladores que não recebiam a sessão.
        param($Aplicada)
        $alvo = Get-SessaoParaReverter -Cliente T -Script VisualEnergia -Pasta $Aplicada.Pasta -Raiz $script:raizSessoes
        $sr = New-SessaoTeste
        Invoke-Reversao -Sessao $sr -Alvo $alvo -Manipuladores (Get-ManipuladorReversao)
        $sr
    }
}
AfterAll { Remove-Item $script:raizSessoes -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Get-CapacidadeEnergia' {
    It 'Lê S3, hibernação e Modern Standby como booleanos' {
        $c = Get-CapacidadeEnergia
        $c.S3 | Should -BeOfType [bool]
        $c.Hibernacao | Should -BeOfType [bool]
        $c.ModernStandby | Should -BeOfType [bool]
    }
}

Describe 'V3 plano Desempenho máximo' {
    BeforeAll { $script:planoOriginal = Get-PlanoAtivo }
    AfterAll {
        & powercfg.exe /setactive $script:planoOriginal | Out-Null
        if (Test-PlanoExiste $script:GuidPlanoProjeto) { & powercfg.exe /delete $script:GuidPlanoProjeto | Out-Null }
    }

    It 'Cria o plano com GUID do projeto, ativa, é idempotente e a reversão restaura e exclui' {
        $s = New-SessaoTeste
        Invoke-V3 -Sessao $s
        $l = $s.Linhas | Where-Object Item -eq 'V3' | Select-Object -Last 1
        if ((Get-CapacidadeEnergia).ModernStandby) { Set-ItResult -Skipped -Because 'VM em Modern Standby'; return }
        $l.Resultado | Should -Be 'OK'
        Get-PlanoAtivo | Should -Be $script:GuidPlanoProjeto

        $s2 = New-SessaoTeste
        Invoke-V3 -Sessao $s2
        ($s2.Linhas | Where-Object Item -eq 'V3').Resultado | Should -Be 'JaAplicado'

        $sr = Invoke-ReversaoTeste -Aplicada $s
        @($sr.Linhas | Where-Object Resultado -eq 'Falha').Count | Should -Be 0 -Because (($sr.Linhas | Where-Object Resultado -eq 'Falha').Detalhe -join '; ')
        Get-PlanoAtivo | Should -Be $script:planoOriginal
        Test-PlanoExiste $script:GuidPlanoProjeto | Should -BeFalse
    }

    It 'Reversão simulada do plano não executa powercfg e registra Simulado' {
        Mock Invoke-Powercfg { }
        $sr = New-SessaoOtimizacao -Cliente T -Script VisualEnergia -Simular
        $alvo = [pscustomobject]@{ Pasta = $TestDrive; Entradas = @([pscustomobject]@{ Tipo = 'PlanoEnergia'; Item = 'V3'; Original = $script:GuidEquilibrado; Criado = $script:GuidPlanoProjeto }) }
        Invoke-Reversao -Sessao $sr -Alvo $alvo -Manipuladores (Get-ManipuladorReversao)
        Should -Invoke Invoke-Powercfg -Times 0
        ($sr.Linhas | Where-Object Item -eq 'V3').Resultado | Should -Be 'Simulado'
    }

    It 'Modern Standby sem plano disponível: pula, mantém o plano e explica' {
        Mock Get-CapacidadeEnergia { [pscustomobject]@{ S3 = $false; Hibernacao = $true; ModernStandby = $true } }
        Mock Get-PlanoAtivo { $script:GuidEquilibrado }
        Mock Test-PlanoExiste { $false }
        Mock Invoke-Powercfg { throw 'Parâmetros inválidos' }
        $s = New-SessaoTeste
        Invoke-V3 -Sessao $s
        $l = $s.Linhas | Where-Object Item -eq 'V3'
        $l.Resultado | Should -Be 'Pulado'
        $l.Detalhe | Should -BeLike '*Modern Standby*'
    }

    It 'Simulação não cria nem ativa plano' {
        $s = New-SessaoOtimizacao -Cliente T -Script VisualEnergia -Simular
        $antes = Get-PlanoAtivo
        Invoke-V3 -Sessao $s
        Get-PlanoAtivo | Should -Be $antes
        Test-PlanoExiste $script:GuidPlanoProjeto | Should -BeFalse
        ($s.Linhas | Where-Object Item -eq 'V3').Resultado | Should -Be 'Simulado'
    }
}

Describe 'V6 hibernação' {
    It 'Notebook: pulado' {
        Mock Get-TipoEquipamento { 'Notebook' }
        $s = New-SessaoTeste
        Invoke-V6 -Sessao $s
        ($s.Linhas | Where-Object Item -eq 'V6').Resultado | Should -Be 'Pulado'
    }

    It 'Desktop: desliga, relê e a reversão religa (se a VM tiver hibernação disponível)' {
        Mock Get-TipoEquipamento { 'Desktop' }
        & powercfg.exe /hibernate on 2>$null | Out-Null
        if (-not (Get-CapacidadeEnergia).Hibernacao) { Set-ItResult -Skipped -Because 'Hibernação indisponível na VM'; return }
        $s = New-SessaoTeste
        Invoke-V6 -Sessao $s
        (Get-CapacidadeEnergia).Hibernacao | Should -BeFalse
        Invoke-ReversaoTeste -Aplicada $s | Out-Null
        (Get-CapacidadeEnergia).Hibernacao | Should -BeTrue
    }
}

Describe 'Itens do usuário no hive de outra conta' {
    BeforeAll {
        $script:alvo = Get-UsuarioAlvo
        $script:info = Get-InfoWindows
    }

    It 'Executado pelo Administrador, grava no HKCU do usuário do console e não no próprio' {
        $script:alvo.Sid | Should -Not -Be ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
        $proprio = Get-ValorRegistro -Caminho 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Nome 'HideFileExt'
        $numAntes = (Get-ValorRegistro "Registry::HKEY_USERS\$($script:alvo.Sid)\Control Panel\Keyboard" 'InitialKeyboardIndicators').Valor
        $s = New-SessaoTeste
        Invoke-ItemUsuario -Sessao $s -Alvo $script:alvo -Itens @('V1', 'V2', 'V7', 'V8', 'V9', 'V10') -Info $script:info
        @($s.Linhas | Where-Object Resultado -eq 'Falha').Count | Should -Be 0 -Because (($s.Linhas | Where-Object Resultado -eq 'Falha').Detalhe -join '; ')

        $r = "Registry::HKEY_USERS\$($script:alvo.Sid)"
        (Get-ValorRegistro "$r\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" 'HideFileExt').Valor | Should -Be 0
        (Get-ValorRegistro "$r\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" 'EnableTransparency').Valor | Should -Be 0
        # Usuário conectado: V7 não grava (o Windows sobrescreve ao sair), salvo se já estiver em 2.
        if ([string]$numAntes -ne '2') {
            ($s.Linhas | Where-Object Item -eq 'V7').Resultado | Should -Be 'Pulado'
            (Get-ValorRegistro "$r\Control Panel\Keyboard" 'InitialKeyboardIndicators').Valor | Should -Be $numAntes
        }
        (Get-ValorRegistro "$r\Control Panel\Desktop\WindowMetrics" 'MinAnimate').Valor | Should -Be '0'
        ([int](Get-ValorRegistro "$r\Control Panel\Accessibility\StickyKeys" 'Flags').Valor -band 4) | Should -Be 0
        $mascara = (Get-ValorRegistro "$r\Control Panel\Desktop" 'UserPreferencesMask').Valor
        ($mascara[0] -band 0x0E) | Should -Be 0
        ($mascara[1] -band 0x1E) | Should -Be 0
        (Get-ValorRegistro 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'HideFileExt').Valor | Should -Be $proprio.Valor

        $s2 = New-SessaoTeste
        Invoke-ItemUsuario -Sessao $s2 -Alvo $script:alvo -Itens @('V1', 'V2', 'V7', 'V8', 'V9', 'V10') -Info $script:info
        @($s2.Linhas | Where-Object { $_.Resultado -notin 'JaAplicado', 'Pulado' }).Count | Should -Be 0

        $antesReversao = $s.Entradas | Where-Object Nome -eq 'HideFileExt'
        Invoke-ReversaoTeste -Aplicada $s | Out-Null
        $depois = Get-ValorRegistro "$r\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" 'HideFileExt'
        $depois.Existe | Should -Be $antesReversao.Existia
        if ($antesReversao.Existia) { $depois.Valor | Should -Be $antesReversao.Valor }
    }

    It 'V9 é pulado em build anterior a 22631' {
        $s = New-SessaoTeste
        Invoke-ItemUsuario -Sessao $s -Alvo $script:alvo -Itens @('V9') -Info ([pscustomobject]@{ Build = 22621 })
        ($s.Linhas | Where-Object Item -eq 'V9').Resultado | Should -Be 'Pulado'
    }
}

Describe 'Invoke-VisualEnergia' {
    BeforeAll {
        $script:perfil = Join-Path $env:TEMP 'perfil-ve.psd1'
        "@{ Cliente = 'TesteVM'; Aplicar = @('V3','V8') }" | Out-File $script:perfil -Encoding UTF8
    }
    It 'Falha no ponto de restauração: nada é aplicado' {
        Mock Test-PreCondicao { [pscustomobject]@{ Bloqueios = @(); Avisos = @() } }
        Mock New-PontoRestauracao { throw 'Proteção do Sistema desativada' }
        Mock Invoke-V3 { }
        Mock Invoke-ItemUsuario { }
        { Invoke-VisualEnergia -Perfil $script:perfil } | Should -Throw '*Backup falhou*'
        Should -Invoke Invoke-V3 -Times 0
        Should -Invoke Invoke-ItemUsuario -Times 0
    }
}
