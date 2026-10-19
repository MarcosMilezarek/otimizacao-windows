# Testes que alteram o sistema: executar SOMENTE na VM de teste (tools\Testar-NaVM.ps1 define OTIMIZACAO_VM=1).
BeforeAll {
    if ($env:OTIMIZACAO_VM -ne '1') { throw 'Inicializacao.Tests.ps1 só pode rodar na VM de teste (OTIMIZACAO_VM=1).' }
    # -Perfil obrigatório: valor fictício só para o binding; com dot-source o script não executa.
    . (Join-Path $PSScriptRoot '..\src\Inicializacao.ps1') -Perfil 'nao-usado.psd1'
    $script:raizSessoes = Join-Path $env:TEMP ('sessoes-' + [guid]::NewGuid())
    function New-SessaoTeste { New-SessaoOtimizacao -Cliente T -Script Inicializacao -Raiz $script:raizSessoes }
    function Invoke-ReversaoTeste {
        param($Aplicada)
        $alvo = Get-SessaoParaReverter -Cliente T -Script Inicializacao -Pasta $Aplicada.Pasta -Raiz $script:raizSessoes
        $sr = New-SessaoTeste
        Invoke-Reversao -Sessao $sr -Alvo $alvo -Manipuladores (Get-ManipuladorReversao)
        $sr
    }
    function New-PerfilTeste { param([hashtable]$Opcoes = @{}, [hashtable]$Protegidos = @{}) [pscustomobject]@{ Cliente = 'T'; UsuarioSid = $null; Aplicar = @(); Pular = @(); Protegidos = $Protegidos; Opcoes = $Opcoes } }
    function Get-Falhas { param($Sessao) @($Sessao.Linhas | Where-Object Resultado -eq 'Falha') }
}
AfterAll { Remove-Item $script:raizSessoes -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Get-ExecutavelComando e Test-ComponenteWindows' {
    It '<Comando> -> <Esperado>' -ForEach @(
        @{ Comando = '"C:\Program Files\App\a.exe" --min'; Esperado = 'C:\Program Files\App\a.exe' }
        @{ Comando = 'C:\Program Files\Sem Aspas\b.exe /x'; Esperado = 'C:\Program Files\Sem Aspas\b.exe' }
        @{ Comando = '%windir%\system32\SecurityHealthSystray.exe'; Esperado = "$env:windir\system32\SecurityHealthSystray.exe" }
    ) {
        Get-ExecutavelComando $Comando | Should -Be $Esperado
    }

    It 'Reconhece componente do Windows e rejeita terceiros' {
        Test-ComponenteWindows '%windir%\system32\SecurityHealthSystray.exe' | Should -BeTrue
        Test-ComponenteWindows '"%SystemRoot%\System32\svchost.exe" -k netsvcs' | Should -BeTrue
        Test-ComponenteWindows '"C:\Program Files\App\a.exe"' | Should -BeFalse
        Test-ComponenteWindows '' | Should -BeFalse
    }
}

Describe 'I1 entradas de inicialização no registro real da VM' {
    BeforeAll {
        $script:alvo = Get-UsuarioAlvo
        $script:runM = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
        $script:aprovM = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
        $script:runU = "Registry::HKEY_USERS\$($script:alvo.Sid)\Software\Microsoft\Windows\CurrentVersion\Run"
        $script:aprovU = "Registry::HKEY_USERS\$($script:alvo.Sid)\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"
        New-Item $script:runU -Force | Out-Null
        New-ItemProperty $script:runM -Name 'E2ETesteRun' -Value '"C:\Program Files\E2E\a.exe" /bg' -Force | Out-Null
        New-ItemProperty $script:runU -Name 'E2ETesteUsuario' -Value 'C:\Users\Public\e2e.exe' -Force | Out-Null
        $script:securityAntes = (Get-ValorRegistro $script:aprovM 'SecurityHealth').Valor
    }
    AfterAll {
        Remove-ItemProperty $script:runM -Name 'E2ETesteRun' -ErrorAction SilentlyContinue
        Remove-ItemProperty $script:runU -Name 'E2ETesteUsuario' -ErrorAction SilentlyContinue
    }

    It 'Desabilita máquina e usuário, pula componente do Windows e entrada inexistente, é idempotente e reverte' {
        $perfil = New-PerfilTeste -Opcoes @{ I1Desabilitar = @('E2ETesteRun', 'E2ETesteUsuario', 'SecurityHealth', 'NaoExiste') }
        $s = New-SessaoTeste
        Invoke-I1 -Sessao $s -Perfil $perfil -Alvo $script:alvo
        Get-Falhas $s | Should -HaveCount 0 -Because ((Get-Falhas $s).Detalhe -join '; ')
        ((Get-ValorRegistro $script:aprovM 'E2ETesteRun').Valor[0] -band 1) | Should -Be 1
        ((Get-ValorRegistro $script:aprovU 'E2ETesteUsuario').Valor[0] -band 1) | Should -Be 1
        ($s.Linhas | Where-Object Alvo -like '*SecurityHealth').Resultado | Should -Be 'Pulado'
        (Get-ValorRegistro $script:aprovM 'SecurityHealth').Valor | Should -Be $script:securityAntes
        ($s.Linhas | Where-Object Alvo -eq 'NaoExiste').Resultado | Should -Be 'Pulado'

        $s2 = New-SessaoTeste
        Invoke-I1 -Sessao $s2 -Perfil $perfil -Alvo $script:alvo
        @($s2.Linhas | Where-Object Resultado -eq 'JaAplicado') | Should -HaveCount 2

        $sr = Invoke-ReversaoTeste -Aplicada $s
        Get-Falhas $sr | Should -HaveCount 0 -Because ((Get-Falhas $sr).Detalhe -join '; ')
        (Get-ValorRegistro $script:aprovM 'E2ETesteRun').Existe | Should -BeFalse
        (Get-ValorRegistro $script:aprovU 'E2ETesteUsuario').Existe | Should -BeFalse
    }

    It 'Nome em Protegidos.Inicializacao é pulado' {
        $perfil = New-PerfilTeste -Opcoes @{ I1Desabilitar = @('E2ETesteRun') } -Protegidos @{ Inicializacao = @('E2E*') }
        $s = New-SessaoTeste
        Invoke-I1 -Sessao $s -Perfil $perfil -Alvo $script:alvo
        ($s.Linhas | Where-Object Alvo -like '*E2ETesteRun').Detalhe | Should -BeLike '*Protegido*'
        (Get-ValorRegistro $script:aprovM 'E2ETesteRun').Existe | Should -BeFalse
    }

    It 'Lista vazia: pula sem alterar' {
        $s = New-SessaoTeste
        Invoke-I1 -Sessao $s -Perfil (New-PerfilTeste) -Alvo $script:alvo
        ($s.Linhas | Where-Object Item -eq 'I1').Resultado | Should -Be 'Pulado'
    }
}

Describe 'Políticas de máquina (I2, I3, I4, I5, I8) no registro real da VM' {
    It 'Aplica, é idempotente e reverte removendo as chaves criadas' {
        Mock Test-UcpdAtivo { $false }
        $chaves = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy', 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR'
        $existiam = $chaves | ForEach-Object { Test-Path $_ }
        $perfil = New-PerfilTeste -Opcoes @{ I4NegarSegundoPlano = @('Microsoft.BingNews_8wekyb3d8bbwe', 'Microsoft.BingWeather_8wekyb3d8bbwe') }
        $info = Get-InfoWindows
        $s = New-SessaoTeste
        Invoke-I2 -Sessao $s; Invoke-I3 -Sessao $s; Invoke-I4 -Sessao $s -Perfil $perfil; Invoke-I5 -Sessao $s -Info $info; Invoke-I8 -Sessao $s
        Get-Falhas $s | Should -HaveCount 0 -Because ((Get-Falhas $s).Detalhe -join '; ')
        (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Edge').StartupBoostEnabled | Should -Be 0
        (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Edge').BackgroundModeEnabled | Should -Be 0
        if (-not (Test-AppInstalado 'chrome.exe')) { ($s.Linhas | Where-Object Item -eq 'I3').Resultado | Should -Be 'Pulado' }
        $ap = Get-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'
        $ap.GetValueKind('LetAppsRunInBackground_ForceDenyTheseApps') | Should -Be 'MultiString'
        @($ap.GetValue('LetAppsRunInBackground_ForceDenyTheseApps')) | Should -Be @('Microsoft.BingNews_8wekyb3d8bbwe', 'Microsoft.BingWeather_8wekyb3d8bbwe')
        $ap.GetValue('LetAppsRunInBackground') | Should -Be 0
        (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh').AllowNewsAndInterests | Should -Be 0
        (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR').AllowGameDVR | Should -Be 0

        $s2 = New-SessaoTeste
        Invoke-I2 -Sessao $s2; Invoke-I4 -Sessao $s2 -Perfil $perfil; Invoke-I5 -Sessao $s2 -Info $info; Invoke-I8 -Sessao $s2
        @($s2.Linhas | Where-Object { $_.Resultado -ne 'JaAplicado' }) | Should -HaveCount 0

        $sr = Invoke-ReversaoTeste -Aplicada $s
        Get-Falhas $sr | Should -HaveCount 0
        ($chaves | ForEach-Object { Test-Path $_ }) | Should -Be $existiam
    }

    It 'I5 com UCPD ativo: pula com orientação sem criar a chave' {
        Mock Test-UcpdAtivo { $true }
        $existia = Test-Path 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh'
        $s = New-SessaoTeste
        Invoke-I5 -Sessao $s -Info (Get-InfoWindows)
        $l = $s.Linhas | Where-Object Item -eq 'I5'
        $l.Resultado | Should -Be 'Pulado'
        $l.Detalhe | Should -BeLike '*UCPD*Configurações*'
        Test-Path 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' | Should -Be $existia
    }

    It 'I4: lista vazia é pulada e nome inválido falha sem gravar' {
        $s = New-SessaoTeste
        Invoke-I4 -Sessao $s -Perfil (New-PerfilTeste)
        ($s.Linhas | Where-Object Item -eq 'I4').Resultado | Should -Be 'Pulado'
        { Invoke-I4 -Sessao (New-SessaoTeste) -Perfil (New-PerfilTeste -Opcoes @{ I4NegarSegundoPlano = @('nome invalido') }) } | Should -Throw '*inválido*'
        Test-Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' | Should -BeFalse
    }

    It 'Política já definida com outro valor (GPO) é pulada e preservada' {
        New-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' -Force | Out-Null
        New-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' -Name AllowGameDVR -Value 1 -PropertyType DWord -Force | Out-Null
        $s = New-SessaoTeste
        Invoke-I8 -Sessao $s
        ($s.Linhas | Where-Object Item -eq 'I8').Resultado | Should -Be 'Pulado'
        (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR').AllowGameDVR | Should -Be 1
        Remove-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' -Recurse -Force
    }
}

Describe 'I6 Copilot (mocks: a VM não tem o app)' {
    It 'Não instalado: JaAplicado, nada removido' {
        Mock Get-AppxPackage { }
        Mock Get-AppxProvisionedPackage { }
        Mock Remove-AppxPackage { }
        $s = New-SessaoTeste
        Invoke-I6 -Sessao $s
        ($s.Linhas | Where-Object Item -eq 'I6').Resultado | Should -Be 'JaAplicado'
        Should -Invoke Remove-AppxPackage -Times 0
    }

    It 'Instalado: remove de todos os usuários e da imagem; consulta só o pacote Microsoft.Copilot' {
        $script:presente = $true
        Mock Get-AppxPackage { if ($script:presente) { [pscustomobject]@{ Name = 'Microsoft.Copilot'; PackageFullName = 'Microsoft.Copilot_1.0.0.0_x64__8wekyb3d8bbwe' } } }
        Mock Get-AppxProvisionedPackage { if ($script:presente) { [pscustomobject]@{ DisplayName = 'Microsoft.Copilot'; PackageName = 'Microsoft.Copilot_1.0.0.0_neutral_~_8wekyb3d8bbwe' } } }
        Mock Remove-AppxPackage { $script:presente = $false }
        Mock Remove-AppxProvisionedPackage { }
        $s = New-SessaoTeste
        Invoke-I6 -Sessao $s
        Should -Invoke Get-AppxPackage -ParameterFilter { $Name -eq 'Microsoft.Copilot' -and $AllUsers }
        Should -Invoke Get-AppxPackage -Times 0 -ParameterFilter { $Name -ne 'Microsoft.Copilot' }
        Should -Invoke Remove-AppxPackage -Times 1 -ParameterFilter { $AllUsers -and $Package -like 'Microsoft.Copilot_*' }
        Should -Invoke Remove-AppxProvisionedPackage -Times 1
        ($s.Entradas | Where-Object Tipo -eq 'AppRemovido').Nome | Should -Be 'Microsoft.Copilot'
        $sr = Invoke-ReversaoTeste -Aplicada $s
        ($sr.Linhas | Where-Object Item -eq 'I6').Resultado | Should -Be 'Pulado'
    }

    It 'Simulação não remove' {
        Mock Get-AppxPackage { [pscustomobject]@{ Name = 'Microsoft.Copilot'; PackageFullName = 'Microsoft.Copilot_1_x64__8wekyb3d8bbwe' } }
        Mock Get-AppxProvisionedPackage { }
        Mock Remove-AppxPackage { }
        $s = New-SessaoOtimizacao -Cliente T -Script Inicializacao -Simular
        Invoke-I6 -Sessao $s
        Should -Invoke Remove-AppxPackage -Times 0
        ($s.Linhas | Where-Object Item -eq 'I6').Resultado | Should -Be 'Simulado'
    }
}

Describe 'I9 tarefas agendadas' {
    BeforeAll {
        $acao = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument '/c exit 0'
        Register-ScheduledTask -TaskPath '\E2E\' -TaskName 'TarefaTeste' -Action $acao -Force | Out-Null
        $script:defragAntes = [string](Get-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag').State
    }
    AfterAll { Unregister-ScheduledTask -TaskPath '\E2E\' -TaskName 'TarefaTeste' -Confirm:$false -ErrorAction SilentlyContinue }

    It 'Desabilita terceiro, recusa \Microsoft\, é idempotente e reverte' {
        $perfil = New-PerfilTeste -Opcoes @{ I9Tarefas = @('\E2E\TarefaTeste', '\Microsoft\Windows\Defrag\ScheduledDefrag', '\E2E\NaoExiste') }
        $s = New-SessaoTeste
        Invoke-I9 -Sessao $s -Perfil $perfil
        Get-Falhas $s | Should -HaveCount 0 -Because ((Get-Falhas $s).Detalhe -join '; ')
        [string](Get-ScheduledTask -TaskPath '\E2E\' -TaskName 'TarefaTeste').State | Should -Be 'Disabled'
        ($s.Linhas | Where-Object Alvo -like '*ScheduledDefrag').Resultado | Should -Be 'Pulado'
        [string](Get-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag').State | Should -Be $script:defragAntes
        ($s.Linhas | Where-Object Alvo -eq '\E2E\NaoExiste').Resultado | Should -Be 'Pulado'

        $s2 = New-SessaoTeste
        Invoke-I9 -Sessao $s2 -Perfil (New-PerfilTeste -Opcoes @{ I9Tarefas = @('\E2E\TarefaTeste') })
        ($s2.Linhas | Where-Object Item -eq 'I9').Resultado | Should -Be 'JaAplicado'

        $sr = Invoke-ReversaoTeste -Aplicada $s
        Get-Falhas $sr | Should -HaveCount 0 -Because ((Get-Falhas $sr).Detalhe -join '; ')
        [string](Get-ScheduledTask -TaskPath '\E2E\' -TaskName 'TarefaTeste').State | Should -Be 'Ready'
    }

    It 'Reversão simulada não altera a tarefa' {
        Disable-ScheduledTask -TaskPath '\E2E\' -TaskName 'TarefaTeste' | Out-Null
        $sr = New-SessaoOtimizacao -Cliente T -Script Inicializacao -Simular
        $alvo = [pscustomobject]@{ Pasta = $TestDrive; Entradas = @([pscustomobject]@{ Tipo = 'Tarefa'; Item = 'I9'; Caminho = '\E2E\'; Nome = 'TarefaTeste'; Estado = 'Ready' }) }
        Invoke-Reversao -Sessao $sr -Alvo $alvo -Manipuladores (Get-ManipuladorReversao)
        [string](Get-ScheduledTask -TaskPath '\E2E\' -TaskName 'TarefaTeste').State | Should -Be 'Disabled'
        ($sr.Linhas | Where-Object Item -eq 'I9').Resultado | Should -Be 'Simulado'
        Enable-ScheduledTask -TaskPath '\E2E\' -TaskName 'TarefaTeste' | Out-Null
    }
}

Describe 'I10 serviços' {
    BeforeAll {
        New-Service -Name 'E2ESvcTeste' -BinaryPathName '"C:\Program Files\E2E\svc.exe"' -StartupType Automatic | Out-Null
        New-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\E2ESvcTeste' -Name DelayedAutostart -Value 1 -PropertyType DWord -Force | Out-Null
        $script:spoolerAntes = (Get-InicioServico 'Spooler').Start
        $script:diskAntes = (Get-InicioServico 'disk').Start
    }
    AfterAll { & sc.exe delete E2ESvcTeste | Out-Null }

    It 'Muda serviço de terceiro, recusa serviço do Windows e driver, é idempotente e reverte o início atrasado' {
        $perfil = New-PerfilTeste -Opcoes @{ I10Servicos = @{ E2ESvcTeste = 'Manual'; Spooler = 'Disabled'; disk = 'Disabled'; NaoExiste = 'Manual' } }
        $s = New-SessaoTeste
        Invoke-I10 -Sessao $s -Perfil $perfil
        Get-Falhas $s | Should -HaveCount 0 -Because ((Get-Falhas $s).Detalhe -join '; ')
        (Get-InicioServico 'E2ESvcTeste').Start | Should -Be 3
        ($s.Linhas | Where-Object Alvo -eq 'Spooler').Resultado | Should -Be 'Pulado'
        ($s.Linhas | Where-Object Alvo -eq 'disk').Resultado | Should -Be 'Pulado'
        ($s.Linhas | Where-Object Alvo -eq 'NaoExiste').Resultado | Should -Be 'Pulado'
        (Get-InicioServico 'Spooler').Start | Should -Be $script:spoolerAntes
        (Get-InicioServico 'disk').Start | Should -Be $script:diskAntes

        $s2 = New-SessaoTeste
        Invoke-I10 -Sessao $s2 -Perfil (New-PerfilTeste -Opcoes @{ I10Servicos = @{ E2ESvcTeste = 'Manual' } })
        ($s2.Linhas | Where-Object Item -eq 'I10').Resultado | Should -Be 'JaAplicado'

        $sr = Invoke-ReversaoTeste -Aplicada $s
        Get-Falhas $sr | Should -HaveCount 0 -Because ((Get-Falhas $sr).Detalhe -join '; ')
        $depois = Get-InicioServico 'E2ESvcTeste'
        $depois.Start | Should -Be 2
        $depois.Atrasado | Should -BeTrue
    }

    It 'Destino inválido falha só naquele serviço' {
        $s = New-SessaoTeste
        Invoke-I10 -Sessao $s -Perfil (New-PerfilTeste -Opcoes @{ I10Servicos = @{ E2ESvcTeste = 'Automatico' } })
        (Get-Falhas $s).Detalhe | Should -BeLike '*inválido*'
        (Get-InicioServico 'E2ESvcTeste').Start | Should -Be 2
    }
}

Describe 'I11 e I12 por edição e hardware (mocks onde a VM não reproduz)' {
    AfterEach {
        Remove-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'I11 no Pro: só informa, sem gravar política de máquina' {
        $s = New-SessaoTeste
        Invoke-I11Maquina -Sessao $s -Info ([pscustomobject]@{ EditionId = 'Professional' })
        ($s.Linhas | Where-Object Item -eq 'I11').Resultado | Should -Be 'Info'
        Test-Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' | Should -BeFalse
    }

    It 'I11 no Enterprise: grava as duas políticas' {
        $s = New-SessaoTeste
        Invoke-I11Maquina -Sessao $s -Info ([pscustomobject]@{ EditionId = 'EnterpriseEval' })
        $cc = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'
        $cc.DisableWindowsConsumerFeatures | Should -Be 1
        $cc.DisableSoftLanding | Should -Be 1
    }

    It 'I12 sem conteúdo do Recall (não Copilot+): pulado' {
        Mock Get-EstadoRecall { 'DisabledWithPayloadRemoved' }
        $s = New-SessaoTeste
        Invoke-I12 -Sessao $s -Info ([pscustomobject]@{ Build = 26100; UBR = 4000 })
        ($s.Linhas | Where-Object Item -eq 'I12').Resultado | Should -Be 'Pulado'
        Test-Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' | Should -BeFalse
    }

    It 'I12 em Copilot+ (Recall presente): grava as duas políticas' {
        Mock Get-EstadoRecall { 'Disabled' }
        $s = New-SessaoTeste
        Invoke-I12 -Sessao $s -Info ([pscustomobject]@{ Build = 26100; UBR = 4000 })
        $ai = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'
        $ai.DisableAIDataAnalysis | Should -Be 1
        $ai.DisableClickToDo | Should -Be 1
    }
}

Describe 'Itens do usuário (I7, I11) no hive de outra conta' {
    It 'Executado pelo Administrador, grava no HKCU do usuário do console, não no próprio, e reverte' {
        $alvo = Get-UsuarioAlvo
        $alvo.Sid | Should -Not -Be ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
        $r = "Registry::HKEY_USERS\$($alvo.Sid)"
        $s = New-SessaoTeste
        Invoke-ItemUsuario -Sessao $s -Alvo $alvo -Itens @('I7', 'I11')
        Get-Falhas $s | Should -HaveCount 0 -Because ((Get-Falhas $s).Detalhe -join '; ')
        (Get-ValorRegistro "$r\Software\Policies\Microsoft\Windows\Explorer" 'DisableSearchBoxSuggestions').Valor | Should -Be 1
        (Get-ValorRegistro "$r\Software\Policies\Microsoft\Windows\CloudContent" 'DisableThirdPartySuggestions').Valor | Should -Be 1
        (Get-ValorRegistro 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions').Existe | Should -BeFalse
        ($s.Linhas | Where-Object { $_.Item -eq 'I7' -and $_.Resultado -eq 'Info' }).Detalhe | Should -BeLike '*Confiança baixa*'

        $sr = Invoke-ReversaoTeste -Aplicada $s
        Get-Falhas $sr | Should -HaveCount 0
        (Get-ValorRegistro "$r\Software\Policies\Microsoft\Windows\Explorer" 'DisableSearchBoxSuggestions').Existe | Should -BeFalse
        (Get-ValorRegistro "$r\Software\Policies\Microsoft\Windows\CloudContent" 'DisableThirdPartySuggestions').Existe | Should -BeFalse
    }
}

Describe 'Invoke-Inicializacao' {
    BeforeAll {
        $script:perfilArq = Join-Path $env:TEMP 'perfil-ini.psd1'
        "@{ Cliente = 'TesteVM'; Aplicar = @('I5','I8') }" | Out-File $script:perfilArq -Encoding UTF8
    }
    It 'Falha no ponto de restauração: nada é aplicado' {
        Mock Test-PreCondicao { [pscustomobject]@{ Bloqueios = @(); Avisos = @() } }
        Mock New-PontoRestauracao { throw 'Proteção do Sistema desativada' }
        Mock Invoke-I5 { }
        Mock Invoke-I8 { }
        { Invoke-Inicializacao -Perfil $script:perfilArq } | Should -Throw '*Backup falhou*'
        Should -Invoke Invoke-I5 -Times 0
        Should -Invoke Invoke-I8 -Times 0
    }
}
