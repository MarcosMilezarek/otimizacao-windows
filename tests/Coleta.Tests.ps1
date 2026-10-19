BeforeAll {
    . (Join-Path $PSScriptRoot '..\src\Coleta.ps1')
}

Describe 'Get-StatusSuporte' {
    It '<Edicao> build <Build> termina em <Fim>' -ForEach @(
        @{ Build = 26100; Edicao = 'Professional'; Fim = '2026-10-13' }
        @{ Build = 26100; Edicao = 'Enterprise'; Fim = '2027-10-12' }
        @{ Build = 26100; Edicao = 'EnterpriseS'; Fim = '2034-10-10' }
        @{ Build = 26200; Edicao = 'Core'; Fim = '2027-10-12' }
        @{ Build = 26300; Edicao = 'Education'; Fim = '2029-10-09' }
        @{ Build = 22631; Edicao = 'Professional'; Fim = '2025-11-11' }
        @{ Build = 19045; Edicao = 'Professional'; Fim = '2025-10-14' }
        @{ Build = 19044; Edicao = 'EnterpriseS'; Fim = '2027-01-12' }
        @{ Build = 19044; Edicao = 'IoTEnterpriseS'; Fim = '2032-01-13' }
        @{ Build = 17763; Edicao = 'EnterpriseS'; Fim = '2029-01-09' }
    ) {
        (Get-StatusSuporte -Build $Build -EditionId $Edicao).FimSuporte | Should -Be $Fim
    }

    It 'Suportado no último dia e não suportado no dia seguinte' {
        (Get-StatusSuporte -Build 26100 -EditionId 'Professional' -Data '2026-10-13').Suportado | Should -BeTrue
        (Get-StatusSuporte -Build 26100 -EditionId 'Professional' -Data '2026-10-14').Suportado | Should -BeFalse
    }

    It 'Windows 10 22H2 avisa sobre ESU' {
        $r = Get-StatusSuporte -Build 19045 -EditionId 'Professional' -Data '2026-10-08'
        $r.Suportado | Should -BeFalse
        $r.Observacao | Should -BeLike '*ESU*'
    }

    It 'Windows 10 anterior ao 22H2 fora do LTSC é sem suporte' {
        (Get-StatusSuporte -Build 19041 -EditionId 'Professional').Suportado | Should -BeFalse
    }

    It 'Build desconhecida não afirma suporte' {
        $r = Get-StatusSuporte -Build 99999 -EditionId 'Professional'
        $r.Suportado | Should -BeNullOrEmpty
        $r.Observacao | Should -BeLike '*fora da tabela*'
    }
}

Describe 'Get-EstadoStartupApproved' {
    It '<Bytes> -> <Esperado>' -ForEach @(
        @{ Bytes = [byte[]](2, 0, 0, 0); Esperado = 'Habilitado' }
        @{ Bytes = [byte[]](6, 0, 0, 0); Esperado = 'Habilitado' }
        @{ Bytes = [byte[]](3, 0, 0, 0); Esperado = 'Desabilitado' }
        @{ Bytes = [byte[]](7, 0, 0, 0); Esperado = 'Desabilitado' }
        @{ Bytes = $null; Esperado = 'Habilitado' }
    ) {
        Get-EstadoStartupApproved $Bytes | Should -Be $Esperado
    }
}

Describe 'Get-TamanhoPasta' {
    It 'Soma arquivos recursivamente, inclusive ocultos, e aceita curinga' {
        $p1 = New-Item -ItemType Directory "TestDrive:\User Data\Default\Cache\sub" -Force
        $p2 = New-Item -ItemType Directory "TestDrive:\User Data\Profile 1\Cache" -Force
        [IO.File]::WriteAllBytes((Join-Path $p1.FullName 'a.bin'), (New-Object byte[] 1MB))
        $oculto = Join-Path $p2.FullName 'b.bin'
        [IO.File]::WriteAllBytes($oculto, (New-Object byte[] 1MB))
        (Get-Item $oculto -Force).Attributes = 'Hidden'
        $r = Get-TamanhoPasta (Join-Path (Get-PSDrive TestDrive).Root 'User Data\*\Cache')
        $r.MB | Should -Be 2
        $r.Arquivos | Should -Be 2
    }

    It 'Caminho inexistente retorna zero sem erro' {
        $r = Get-TamanhoPasta 'TestDrive:\nao-existe'
        $r.MB | Should -Be 0
        $r.Arquivos | Should -Be 0
    }

    It 'Não altera os arquivos medidos' {
        $f = New-Item -ItemType File 'TestDrive:\medir\x.txt' -Force -Value 'conteudo'
        $hash = (Get-FileHash $f.FullName).Hash
        Get-TamanhoPasta 'TestDrive:\medir' | Out-Null
        (Get-FileHash $f.FullName).Hash | Should -Be $hash
    }
}

Describe 'Get-ExecutavelServico' {
    It '<Entrada> -> <Esperado>' -ForEach @(
        @{ Entrada = '"C:\Program Files\App\svc.exe" -k x'; Esperado = 'C:\Program Files\App\svc.exe' }
        @{ Entrada = 'C:\Windows\system32\svchost.exe -k netsvcs -p'; Esperado = 'C:\Windows\system32\svchost.exe' }
        @{ Entrada = 'C:\Program Files\Sem Aspas\svc.exe /run'; Esperado = 'C:\Program Files\Sem Aspas\svc.exe' }
        @{ Entrada = $null; Esperado = $null }
    ) {
        Get-ExecutavelServico $Entrada | Should -Be $Esperado
    }
}

Describe 'Get-EntradaRun e Get-EntradaPastaStartup' {
    BeforeAll {
        # Chaves de registro falsas: nada é gravado no registro do host.
        function New-ChaveFalsa {
            param([hashtable]$Valores)
            $o = [pscustomobject]@{ Valores = $Valores }
            $o | Add-Member ScriptMethod GetValueNames { @($this.Valores.Keys) }
            $o | Add-Member ScriptMethod GetValue { param($n) $this.Valores[$n] }
            $o
        }
        $script:chaves = @{
            'RUN'   = New-ChaveFalsa @{ AppA = '"C:\a.exe"'; AppB = 'C:\b.exe' }
            'APROV' = New-ChaveFalsa @{ AppB = [byte[]](3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0); 'App.lnk' = [byte[]](3, 0, 0, 0) }
        }
        Mock Get-Item -ParameterFilter { $LiteralPath -in 'RUN', 'APROV' } { $script:chaves[$LiteralPath] }
        Mock Get-Item -ParameterFilter { $LiteralPath -eq 'AUSENTE' } { }
    }

    It 'Lê entradas Run e cruza com StartupApproved' {
        $r = @(Get-EntradaRun -ChaveRun 'RUN' -ChaveAprovacao 'APROV' -Origem 'Teste')
        $r.Count | Should -Be 2
        ($r | Where-Object Nome -eq 'AppA').Estado | Should -Be 'Habilitado'
        ($r | Where-Object Nome -eq 'AppB').Estado | Should -Be 'Desabilitado'
        ($r | Where-Object Nome -eq 'AppA').Comando | Should -Be '"C:\a.exe"'
    }

    It 'Chave Run ausente não gera saída nem erro' {
        @(Get-EntradaRun -ChaveRun 'AUSENTE' -ChaveAprovacao 'APROV' -Origem 'Teste').Count | Should -Be 0
    }

    It 'Lê a pasta de inicialização ignorando desktop.ini' {
        New-Item -ItemType File 'TestDrive:\Startup\App.lnk' -Force | Out-Null
        New-Item -ItemType File 'TestDrive:\Startup\desktop.ini' -Force | Out-Null
        $r = @(Get-EntradaPastaStartup -Pasta (Join-Path (Get-PSDrive TestDrive).Root 'Startup') -ChaveAprovacao 'APROV' -Origem 'Teste')
        $r.Count | Should -Be 1
        $r[0].Nome | Should -Be 'App.lnk'
        $r[0].Estado | Should -Be 'Desabilitado'
    }
}

Describe 'Invoke-Coleta' {
    BeforeAll {
        Mock Test-Administrador { $true }
        Mock Get-UsuarioAlvo { [pscustomobject]@{ Sid = 'S-1-5-21-1'; Perfil = 'C:\x' } }
        Mock Get-SecaoSistema { [pscustomobject]@{ Build = 26100 } }
        Mock Get-SecaoDesempenho { [pscustomobject]@{ TotalProcessos = 1 } }
        Mock Get-SecaoUsuario { [pscustomobject]@{ Inicializacao = @(); Visual = $null; Programas = @([pscustomobject]@{ Nome = 'B Usuario'; Tipo = 'EXE'; Escopo = 'Usuario' }) } }
        Mock Get-SecaoPrograma { [pscustomobject]@{ Nome = 'C Maquina'; Tipo = 'MSI'; Escopo = 'Maquina' }; [pscustomobject]@{ Nome = 'A Appx'; Tipo = 'Appx'; Escopo = 'Appx' } }
        Mock Get-SecaoHardware { throw 'falha simulada de hardware' }
        Mock Get-SecaoDisco { [pscustomobject]@{ Volumes = @() } }
        Mock Get-SecaoBitLocker { throw 'Acesso negado' }
        Mock Get-SecaoInicializacaoMaquina { }
        Mock Get-SecaoTarefa { }
        Mock Get-SecaoServico { }
        Mock Get-SecaoEnergia { [pscustomobject]@{ NaBateria = $false } }
        Mock Get-SecaoArmazenamento { [pscustomobject]@{ TotalMB = 0 } }
        Mock Get-SecaoAtualizacao { }
        Mock Get-SecaoBoot { }
        Mock Get-SecaoProtecao { }
        Mock Get-SecaoDispositivo { }
        Mock Get-SecaoEventoHardware { [pscustomobject]@{ Dias = 30 } }
        Mock Get-SecaoBateria { }
    }

    It 'Falha de uma seção não interrompe as demais e fica registrada no JSON' {
        $pasta = Join-Path (Get-PSDrive TestDrive).Root 'saida'
        $arq = Invoke-Coleta -AmostraSegundos 10 -PastaSaida $pasta
        $j = Get-Content $arq.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        @($j.Erros).Count | Should -Be 2
        ($j.Erros | Where-Object Secao -eq 'Hardware').Erro | Should -Be 'falha simulada de hardware'
        $j.Sistema.Build | Should -Be 26100
        $j.Energia.NaBateria | Should -BeFalse
        $j.Hardware | Should -BeNullOrEmpty
        $j.VersaoColeta | Should -Be '1.3.0'
        @($j.Programas | ForEach-Object { $_.Nome }) | Should -Be @('A Appx', 'B Usuario', 'C Maquina')
    }
}

Describe 'Programas instalados' {
    It 'Appx: só não sistema, removível, sem framework e recurso; versão mais nova; provisionamento marcado' {
        Mock Get-ProgramaRegistro { }
        Mock Get-AppxPackage {
            $b = @{ IsFramework = $false; IsResourcePackage = $false; NonRemovable = $false; SignatureKind = 'Store'; InstallLocation = $TestDrive; PackageFullName = 'x' }
            [pscustomobject](@{ Name = 'App.Um'; Version = '1.2.0.0' } + $b)
            [pscustomobject](@{ Name = 'App.Um'; Version = '1.10.0.0' } + $b)
            [pscustomobject](@{ Name = 'App.Prov'; Version = '1.0.0.0' } + $b)
            $s = $b.Clone(); $s.SignatureKind = 'System'; [pscustomobject](@{ Name = 'Sistema'; Version = '1.0.0.0' } + $s)
            $f = $b.Clone(); $f.IsFramework = $true; [pscustomobject](@{ Name = 'Framework'; Version = '1.0.0.0' } + $f)
            $n = $b.Clone(); $n.NonRemovable = $true; [pscustomobject](@{ Name = 'NaoRemovivel'; Version = '1.0.0.0' } + $n)
        }
        Mock Get-AppxProvisionedPackage { [pscustomobject]@{ DisplayName = 'App.Prov' } }
        Mock Get-NomeExibicaoAppx { [pscustomobject]@{ Nome = "Exib $($Pacote.Name)"; Fabricante = 'Fab' } }
        $p = @(Get-SecaoPrograma -Elevado $true)
        @($p | ForEach-Object { $_.Id } | Sort-Object) | Should -Be @('App.Prov', 'App.Um')
        ($p | Where-Object Id -eq 'App.Um').Versao | Should -Be '1.10.0.0'
        ($p | Where-Object Id -eq 'App.Prov').Provisionado | Should -BeTrue
        ($p | Where-Object Id -eq 'App.Um').Provisionado | Should -BeFalse
        ($p | Where-Object Id -eq 'App.Um').Nome | Should -Be 'Exib App.Um'
    }

    It 'Sem elevação: Appx do usuário atual, sem tamanho nem provisionamento' {
        Mock Get-ProgramaRegistro { }
        Mock Get-AppxPackage { [pscustomobject]@{ Name = 'App.Um'; Version = '1.0.0.0'; IsFramework = $false; IsResourcePackage = $false; NonRemovable = $false; SignatureKind = 'Store'; InstallLocation = $TestDrive; PackageFullName = 'x' } }
        Mock Get-AppxProvisionedPackage { throw 'exige elevação' }
        Mock Get-NomeExibicaoAppx { [pscustomobject]@{ Nome = 'App'; Fabricante = $null } }
        $p = @(Get-SecaoPrograma -Elevado $false)
        $p[0].Provisionado | Should -BeNullOrEmpty
        $p[0].TamanhoMB | Should -BeNullOrEmpty
        Should -Invoke Get-AppxPackage -Times 1 -ParameterFilter { -not $AllUsers }
    }

    It 'Comparação: coleta anterior à 1.3.0 fica Sem dado; com a seção, conta os programas' {
        $velha = [pscustomobject]@{ Desempenho = [pscustomobject]@{ Resumo = $null }; Sistema = [pscustomobject]@{ DriveSistema = 'C:' }; Discos = $null; Inicializacao = $null }
        $nova = [pscustomobject]@{ Desempenho = [pscustomobject]@{ Resumo = $null }; Sistema = [pscustomobject]@{ DriveSistema = 'C:' }; Discos = $null; Inicializacao = $null; Programas = @([pscustomobject]@{ Nome = 'a' }, [pscustomobject]@{ Nome = 'b' }) }
        (Get-MetricaColeta $velha | Where-Object Metrica -eq 'Programas e apps instalados').Valor | Should -BeNullOrEmpty
        (Get-MetricaColeta $nova | Where-Object Metrica -eq 'Programas e apps instalados').Valor | Should -Be 2
    }
}

Describe 'M5 Get-SecaoDispositivo' {
    It 'Lista dispositivos com erro, nomeia o código e marca o 22 como desabilitado' {
        Mock Get-CimInstance -ParameterFilter { $ClassName -eq 'Win32_PnPEntity' } {
            [pscustomobject]@{ Name = 'Placa'; PNPClass = 'Net'; Manufacturer = 'X'; PNPDeviceID = 'PCI\A'; ConfigManagerErrorCode = 28 }
            [pscustomobject]@{ Name = 'Leitor'; PNPClass = 'USB'; Manufacturer = 'Y'; PNPDeviceID = 'USB\B'; ConfigManagerErrorCode = 22 }
            [pscustomobject]@{ Name = 'Outro'; PNPClass = 'X'; Manufacturer = 'Z'; PNPDeviceID = 'X\C'; ConfigManagerErrorCode = 99 }
        }
        $r = @(Get-SecaoDispositivo)
        $r.Count | Should -Be 3
        ($r | Where-Object Codigo -eq 28).Problema | Should -Be 'CM_PROB_FAILED_INSTALL'
        ($r | Where-Object Codigo -eq 28).Desabilitado | Should -BeFalse
        ($r | Where-Object Codigo -eq 22).Desabilitado | Should -BeTrue
        ($r | Where-Object Codigo -eq 99).Problema | Should -BeNullOrEmpty
    }
}

Describe 'M6 eventos de hardware' {
    BeforeAll {
        function New-EventoFalso {
            param([string]$Provedor, [int]$Id, [int]$Nivel, [string]$Data, [string[]]$Props = @(), [hashtable]$Nomeados = @{})
            $dados = if ($Nomeados.Count) { ($Nomeados.GetEnumerator() | ForEach-Object { "<Data Name='$($_.Key)'>$($_.Value)</Data>" }) -join '' }
            else { ($Props | ForEach-Object { "<Data>$_</Data>" }) -join '' }
            $o = [pscustomobject]@{
                ProviderName = $Provedor; Id = $Id; Level = $Nivel; TimeCreated = [datetime]$Data
                Properties   = @($Props | ForEach-Object { [pscustomobject]@{ Value = $_ } })
                Xml          = "<Event xmlns='http://schemas.microsoft.com/win/2004/08/events/event'><EventData>$dados</EventData></Event>"
            }
            $o | Add-Member ScriptMethod ToXml { $this.Xml }
            $o
        }
    }

    It 'Resolve-DiscoEvento: <Caso>' -ForEach @(
        @{ Caso = 'HarddiskN no dispositivo'; Disp = '\Device\Harddisk1\DR5'; Vol = $null; Esperado = 1 }
        @{ Caso = 'letra conectada'; Disp = $null; Vol = 'D:'; Esperado = 2 }
        @{ Caso = 'nome NT do volume'; Disp = '\Device\HarddiskVolume3'; Vol = 'OS'; Esperado = 0 }
        @{ Caso = 'volume desconectado'; Disp = '\Device\HarddiskVolume31'; Vol = 'E:'; Esperado = $null }
    ) {
        Resolve-DiscoEvento -Dispositivo $Disp -Volume $Vol -Mapa @{ 'C:' = 0; 'D:' = 2; '\Device\HarddiskVolume3' = 0 } | Should -Be $Esperado
    }

    It 'Get-EventoSistema: provedor inexistente não gera erro nem saída' {
        @(Get-EventoSistema @{ ProviderName = 'ProvedorInexistenteOtimizacao'; StartTime = (Get-Date).AddDays(-1) }).Count | Should -Be 0
    }

    It 'Filtra por provedor, agrupa por disco físico e separa o disco do sistema' {
        Mock Get-EventoSistema -ParameterFilter { $Filtro.ProviderName -eq 'disk' } {
            New-EventoFalso disk 7 2 '2026-10-01T10:00:00' -Props '\Device\Harddisk1\DR1', 'x'
            New-EventoFalso disk 7 2 '2026-10-02T10:00:00' -Props '\Device\Harddisk1\DR7', 'x'
            New-EventoFalso disk 51 3 '2026-10-03T10:00:00' -Props '\Device\Harddisk0\DR0', 'x'
        }
        Mock Get-EventoSistema -ParameterFilter { $Filtro.ProviderName -eq 'Ntfs' } {
            New-EventoFalso Ntfs 55 2 '2026-10-04T10:00:00' -Nomeados @{ DriveName = 'D:'; DeviceName = '\Device\HarddiskVolume31' }
            New-EventoFalso Ntfs 55 2 '2026-10-04T11:00:00' -Nomeados @{ DriveName = 'E:'; DeviceName = '\Device\HarddiskVolume32' }
        }
        Mock Get-EventoSistema -ParameterFilter { $Filtro.ProviderName -eq 'Microsoft-Windows-Ntfs' } { }
        Mock Get-EventoSistema -ParameterFilter { $Filtro.Id -eq 129 } {
            New-EventoFalso 'Microsoft-Windows-Time-Service' 129 3 '2026-10-05T10:00:00'
            New-EventoFalso stornvme 129 3 '2026-10-05T11:00:00' -Props '\Device\RaidPort0'
        }
        Mock Get-EventoSistema -ParameterFilter { $Filtro.ProviderName -eq 'Microsoft-Windows-WHEA-Logger' } { New-EventoFalso 'Microsoft-Windows-WHEA-Logger' 19 3 '2026-10-06T10:00:00' }
        Mock Get-EventoSistema -ParameterFilter { $Filtro.ProviderName -eq 'Microsoft-Windows-Kernel-Power' } { New-EventoFalso 'Microsoft-Windows-Kernel-Power' 41 1 '2026-10-07T10:00:00' }
        Mock Get-MapaDisco { @{ 'C:' = 0; 'D:' = 1 } }
        Mock Get-Disk { [pscustomobject]@{ Number = 0; FriendlyName = 'NVMe Interno'; BusType = 'NVMe' } }
        Mock Get-Partition { [pscustomobject]@{ DiskNumber = 0 } }

        $r = Get-SecaoEventoHardware
        $g = @($r.Grupos)
        $g.Count | Should -Be 7
        $removido = $g | Where-Object { $_.Provedor -eq 'Ntfs' -and $_.Dispositivo -like 'E:*' }
        $removido.Dispositivo | Should -Be 'E: (desconectado)'
        $removido.DiscoDoSistema | Should -BeFalse
        $usb = $g | Where-Object { $_.Provedor -eq 'disk' -and $_.Id -eq 7 }
        $usb.Quantidade | Should -Be 2
        $usb.Dispositivo | Should -Be 'Disco 1'
        $usb.DiscoDoSistema | Should -BeFalse
        $usb.Primeiro | Should -Be '2026-10-01T10:00:00'
        $usb.Ultimo | Should -Be '2026-10-02T10:00:00'
        $interno = $g | Where-Object { $_.Id -eq 51 }
        $interno.DiscoDoSistema | Should -BeTrue
        $interno.Modelo | Should -Be 'NVMe Interno'
        ($g | Where-Object { $_.Provedor -eq 'Ntfs' -and $_.Dispositivo -eq 'Disco 1' }).Quantidade | Should -Be 1
        @($g | Where-Object Provedor -eq 'Microsoft-Windows-Time-Service').Count | Should -Be 0
        ($g | Where-Object Provedor -eq 'stornvme').DiscoDoSistema | Should -BeNullOrEmpty
        $r.Resumo.DiscoDoSistemaErros | Should -Be 0
        $r.Resumo.DiscoDoSistemaAvisos | Should -Be 1
        $r.Resumo.OutrosDiscos | Should -Be 4
        $r.Resumo.DiscoNaoIdentificado | Should -Be 1
        $r.Resumo.HardwareCorrigido | Should -Be 1
        $r.Resumo.HardwareFatal | Should -Be 0
        $r.Resumo.DesligamentosInesperados | Should -Be 1
    }

    It 'Sem eventos: grupos vazios e resumo zerado' {
        Mock Get-EventoSistema { }
        Mock Get-MapaDisco { @{} }
        Mock Get-Disk { }
        Mock Get-Partition { [pscustomobject]@{ DiskNumber = 0 } }
        $r = Get-SecaoEventoHardware
        @($r.Grupos).Count | Should -Be 0
        $r.Resumo.DiscoDoSistemaErros | Should -Be 0
        $r.Resumo.DesligamentosInesperados | Should -Be 0
    }
}

Describe 'M7 relatório de bateria' {
    BeforeAll {
        $script:xmlBateria = @'
<?xml version="1.0" encoding="utf-8"?>
<BatteryReport xmlns="http://schemas.microsoft.com/battery/2012">
  <Batteries>
    <Battery><Id>BAT1</Id><Manufacturer>SMP</Manufacturer><Chemistry>LiP</Chemistry><DesignCapacity>52995</DesignCapacity><FullChargeCapacity>37095</FullChargeCapacity><CycleCount>0</CycleCount></Battery>
    <Battery><Id>BAT2</Id><Manufacturer>X</Manufacturer><Chemistry>LiI</Chemistry><DesignCapacity>0</DesignCapacity><FullChargeCapacity>100</FullChargeCapacity><CycleCount>310</CycleCount></Battery>
  </Batteries>
</BatteryReport>
'@
    }

    It 'Lê capacidades, saúde e ciclos do XML' {
        $r = @(ConvertFrom-RelatorioBateria -Xml ([xml]$script:xmlBateria))
        $r.Count | Should -Be 2
        $r[0].SaudePct | Should -Be 70
        $r[0].ProjetadaMWh | Should -Be 52995
        $r[1].SaudePct | Should -BeNullOrEmpty
        $r[1].Ciclos | Should -Be 310
    }

    It 'Sem bateria: não gera relatório' {
        Mock Get-CimInstance -ParameterFilter { $ClassName -eq 'Win32_Battery' } { }
        Mock Invoke-PowercfgRelatorio { }
        Get-SecaoBateria -Pasta $TestDrive -Prefixo 'PC' | Should -BeNullOrEmpty
        Should -Invoke Invoke-PowercfgRelatorio -Times 0
    }

    It 'Com bateria: HTML na pasta de saída, XML temporário apagado' {
        Mock Get-CimInstance -ParameterFilter { $ClassName -eq 'Win32_Battery' } { [pscustomobject]@{ BatteryStatus = 2 } }
        Mock Invoke-PowercfgRelatorio {
            $destino = $Argumentos[2]
            $conteudo = if ($Argumentos -contains '/xml') { $script:xmlBateria } else { '<html></html>' }
            [IO.File]::WriteAllText($destino, $conteudo)
            Add-Content -LiteralPath (Join-Path $TestDrive 'gerados.txt') -Value $destino
        }
        $r = Get-SecaoBateria -Pasta $TestDrive -Prefixo 'PC01_20261009'
        $r.Relatorio | Should -Be (Join-Path $TestDrive 'PC01_20261009_bateria.html')
        Test-Path $r.Relatorio | Should -BeTrue
        @($r.Baterias).Count | Should -Be 2
        $xmlTemp = Get-Content -LiteralPath (Join-Path $TestDrive 'gerados.txt') | Where-Object { $_ -like '*.xml' }
        $xmlTemp | Should -Not -BeNullOrEmpty
        Test-Path $xmlTemp | Should -BeFalse
        Should -Invoke Invoke-PowercfgRelatorio -Times 2 -ParameterFilter { $Argumentos -contains '/duration' }
    }
}

Describe 'Comparação antes e depois' {
    BeforeAll {
        function New-ColetaFalsa {
            param([double]$Cpu = 10, [double]$Mem = 4000, [int]$Uptime = 10, [bool]$Bateria = $false, [int]$Ubr = 100, [int]$BootMs = 60000, [string]$Pc = 'PC01', [string]$Boot = '2026-10-08T09:00:00')
            $res = [pscustomobject]@{
                CpuPct = [pscustomobject]@{ Media = $Cpu }; MemDisponivelMB = [pscustomobject]@{ Media = $Mem }
                CommitPct = [pscustomobject]@{ Media = 50 }; PaginasSeg = [pscustomobject]@{ Media = 100 }
                DiscoOciosoPct = [pscustomobject]@{ Media = 90 }; FilaDisco = [pscustomobject]@{ Media = 0 }
            }
            [pscustomobject]@{
                Computador = $Pc; Elevado = $true; AmostraSegundos = 60; DataColeta = '2026-10-08T10:00:00'
                Sistema = [pscustomobject]@{ Produto = 'Windows 11 Pro'; Build = 26100; UBR = $Ubr; UptimeMinutos = $Uptime; UltimoBoot = $Boot; DriveSistema = 'C:' }
                Desempenho = [pscustomobject]@{ Resumo = $res; TotalProcessos = 150 }
                Discos = [pscustomobject]@{ Volumes = @([pscustomobject]@{ Letra = 'C'; LivreGB = 50 }) }
                Inicializacao = [pscustomobject]@{ Maquina = @([pscustomobject]@{ Estado = 'Habilitado' }); Usuario = @([pscustomobject]@{ Estado = 'Desabilitado' }) }
                Servicos = @([pscustomobject]@{ Estado = 'Running' }, [pscustomobject]@{ Estado = 'Stopped' })
                Tarefas = @()
                Energia = [pscustomobject]@{ NaBateria = $Bateria }
                Armazenamento = [pscustomobject]@{ TotalMB = 1000 }
                Boot = @([pscustomobject]@{ BootTime = $BootMs; BootPostBootTime = 20000 })
                Programas = @([pscustomobject]@{ Nome = 'Prog' })
            }
        }
    }

    It 'Classifica melhora e piora pela direção de cada métrica' {
        $l = Compare-Coleta -Antes (New-ColetaFalsa -Cpu 10 -Mem 4000 -BootMs 60000) -Depois (New-ColetaFalsa -Cpu 5 -Mem 3000 -BootMs 45000)
        ($l | Where-Object Metrica -like 'CPU*').Resultado | Should -Be 'Melhorou'
        ($l | Where-Object Metrica -like 'Memória disponível*').Resultado | Should -Be 'Piorou'
        $boot = $l | Where-Object Metrica -eq 'Tempo de boot (s)'
        $boot.Antes | Should -Be 60
        $boot.Depois | Should -Be 45
        $boot.DiferencaPct | Should -Be -25
        ($l | Where-Object Metrica -eq 'Itens de inicialização habilitados').Antes | Should -Be 1
        ($l | Where-Object Metrica -eq 'Serviços em execução').Antes | Should -Be 1
        ($l | Where-Object Metrica -like 'Espaço livre*').Antes | Should -Be 50
    }

    It 'Sem eventos de boot, a métrica fica Sem dado' {
        $a = New-ColetaFalsa; $a.Boot = @()
        ($l = Compare-Coleta -Antes $a -Depois (New-ColetaFalsa)) | Out-Null
        ($l | Where-Object Metrica -eq 'Tempo de boot (s)').Resultado | Should -Be 'Sem dado'
    }

    It 'Avisa sobre condições diferentes e sobre ausência de faixa de ruído' {
        $av = @(Get-AvisoCondicao -Antes (New-ColetaFalsa -Uptime 10) -Depois (New-ColetaFalsa -Uptime 60 -Bateria $true -Ubr 200 -Pc 'PC02'))
        $av.Count | Should -Be 5
        $av[0] | Should -BeLike '*sem faixa de ruído*'
    }

    It 'Duas coletas antes com reinicialização e mesmas condições não geram avisos' {
        $antes = @((New-ColetaFalsa -Boot '2026-10-08T08:00:00'), (New-ColetaFalsa -Boot '2026-10-08T09:00:00'))
        @(Get-AvisoCondicao -Antes $antes -Depois (New-ColetaFalsa -Uptime 20)).Count | Should -Be 0
    }

    It 'Avisa quando as coletas antes não tiveram reinicialização entre elas' {
        $antes = @((New-ColetaFalsa), (New-ColetaFalsa))
        @(Get-AvisoCondicao -Antes $antes -Depois (New-ColetaFalsa)) | Should -BeLike '*sem reinicialização*'
    }

    It 'Faixa de ruído: depois <Depois> com antes 10 e 20 -> <Esperado>' -ForEach @(
        @{ Depois = 15; Esperado = 'Dentro do ruído' }
        @{ Depois = 10; Esperado = 'Dentro do ruído' }
        @{ Depois = 20; Esperado = 'Dentro do ruído' }
        @{ Depois = 5; Esperado = 'Melhorou' }
        @{ Depois = 25; Esperado = 'Piorou' }
    ) {
        $antes = @((New-ColetaFalsa -Cpu 10), (New-ColetaFalsa -Cpu 20))
        $cpu = Compare-Coleta -Antes $antes -Depois (New-ColetaFalsa -Cpu $Depois) | Where-Object Metrica -like 'CPU*'
        $cpu.Resultado | Should -Be $Esperado
        $cpu.Antes | Should -Be 15
        $cpu.FaixaAntes | Should -Be '10 a 20'
    }

    It 'Faixa de ruído respeita a direção: memória disponível maior é melhor' {
        $antes = @((New-ColetaFalsa -Mem 3000), (New-ColetaFalsa -Mem 3500))
        (Compare-Coleta -Antes $antes -Depois (New-ColetaFalsa -Mem 4000) | Where-Object Metrica -like 'Memória disponível*').Resultado | Should -Be 'Melhorou'
        (Compare-Coleta -Antes $antes -Depois (New-ColetaFalsa -Mem 2000) | Where-Object Metrica -like 'Memória disponível*').Resultado | Should -Be 'Piorou'
    }

    It 'Métrica determinística sem variação nas coletas antes: igual continua Igual' {
        $antes = @((New-ColetaFalsa), (New-ColetaFalsa))
        (Compare-Coleta -Antes $antes -Depois (New-ColetaFalsa) | Where-Object Metrica -eq 'Serviços em execução').Resultado | Should -Be 'Igual'
    }

    It 'Gera HTML UTF-8 com acentos preservados e conteúdo escapado' {
        $a = New-ColetaFalsa -Pc '<script>'; $d = New-ColetaFalsa -Pc '<script>'
        $saida = Join-Path (Get-PSDrive TestDrive).Root 'cmp.html'
        Export-ComparacaoHtml -Antes $a -Depois $d -Linhas (Compare-Coleta $a $d) -Avisos @('Atenção: teste') -Caminho $saida
        $html = Get-Content $saida -Raw -Encoding UTF8
        $html | Should -BeLike '*Métricas*'
        $html | Should -BeLike '*&lt;script&gt;*'
        $html | Should -Not -BeLike '*<h1>Antes e depois: <script>*'
    }

    It 'Ponta a ponta: powershell.exe -File Coleta.ps1 -Comparar gera o HTML' {
        $raiz = (Get-PSDrive TestDrive).Root
        $a = Join-Path $raiz 'a.json'; $d = Join-Path $raiz 'd.json'; $h = Join-Path $raiz 'e2e.html'
        New-ColetaFalsa -BootMs 60000 | ConvertTo-Json -Depth 8 | Out-File $a -Encoding UTF8
        New-ColetaFalsa -BootMs 50000 | ConvertTo-Json -Depth 8 | Out-File $d -Encoding UTF8
        $script = Join-Path $PSScriptRoot '..\src\Coleta.ps1'
        $a2 = Join-Path $raiz 'a2.json'
        New-ColetaFalsa -BootMs 62000 -Boot '2026-10-08T08:00:00' | ConvertTo-Json -Depth 8 | Out-File $a2 -Encoding UTF8
        $saida = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -Comparar -Antes "$a,$a2" -Depois $d -SaidaHtml $h 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($saida | Out-String)
        Test-Path $h | Should -BeTrue
        $html = Get-Content $h -Raw -Encoding UTF8
        $html | Should -BeLike '*Tempo de boot*'
        $html | Should -BeLike '*60 a 62*'
        $html | Should -BeLike '*<th>Antes 2</th>*'
    }

    It 'Coleta serializada e relida em JSON continua comparável' {
        $arq = Join-Path (Get-PSDrive TestDrive).Root 'c.json'
        New-ColetaFalsa | ConvertTo-Json -Depth 8 | Out-File $arq -Encoding UTF8
        $lida = Get-Content $arq -Raw -Encoding UTF8 | ConvertFrom-Json
        $l = Compare-Coleta -Antes $lida -Depois $lida
        @($l | Where-Object Resultado -eq 'Igual').Count | Should -Be @($l).Count
    }
}
