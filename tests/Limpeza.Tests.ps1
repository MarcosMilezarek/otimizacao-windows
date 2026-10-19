# Testes que alteram o sistema: executar SOMENTE na VM de teste (tools\Testar-NaVM.ps1 define OTIMIZACAO_VM=1).
BeforeAll {
    if ($env:OTIMIZACAO_VM -ne '1') { throw 'Limpeza.Tests.ps1 só pode rodar na VM de teste (OTIMIZACAO_VM=1).' }
    # -Perfil obrigatório: valor fictício só para o binding; com dot-source o script não executa.
    . (Join-Path $PSScriptRoot '..\src\Limpeza.ps1') -Perfil 'nao-usado.psd1'

    function New-ArquivoTeste {
        param([string]$Caminho, [int]$IdadeDias = 0, [int]$Bytes = 1024)
        New-Item -ItemType Directory -Path (Split-Path $Caminho) -Force | Out-Null
        [IO.File]::WriteAllBytes($Caminho, (New-Object byte[] $Bytes))
        if ($IdadeDias) {
            $d = (Get-Date).AddDays(-$IdadeDias)
            (Get-Item $Caminho).CreationTime = $d
            (Get-Item $Caminho).LastWriteTime = $d
        }
        Get-Item $Caminho
    }
    function Get-HashPasta {
        param([string]$Pasta)
        (Get-ChildItem $Pasta -Recurse -File -Force | Sort-Object FullName | ForEach-Object { (Get-FileHash $_.FullName).Hash }) -join ','
    }
}

Describe 'Get-ArquivoLimpeza' {
    BeforeEach {
        $script:raiz = Join-Path $env:TEMP ("teste-limpeza-" + [guid]::NewGuid())
        New-Item -ItemType Directory $script:raiz | Out-Null
    }
    AfterEach { cmd /c rmdir /s /q "$script:raiz" 2>$null }

    It 'Respeita a idade mínima pela data mais recente entre criação e gravação' {
        New-ArquivoTeste "$script:raiz\velho.tmp" -IdadeDias 10 | Out-Null
        New-ArquivoTeste "$script:raiz\novo.tmp" | Out-Null
        $r = @(Get-ArquivoLimpeza -Pasta $script:raiz -IdadeMinimaDias 7)
        $r.Name | Should -Be 'velho.tmp'
    }

    It 'Não segue ponto de junção: arquivos do destino ficam fora da lista' {
        $docs = Join-Path $env:TEMP ("docs-" + [guid]::NewGuid())
        New-ArquivoTeste "$docs\contrato.docx" -IdadeDias 30 | Out-Null
        cmd /c mklink /J "$script:raiz\juncao" "$docs" | Out-Null
        (Get-Item "$script:raiz\juncao" -Force).Attributes -band [IO.FileAttributes]::ReparsePoint | Should -Not -Be 0
        @(Get-ArquivoLimpeza -Pasta $script:raiz).Count | Should -Be 0
        cmd /c rmdir "$script:raiz\juncao" | Out-Null
        Remove-Item $docs -Recurse -Force
    }

    It 'Raiz que é ponto de junção não é varrida' {
        $docs = Join-Path $env:TEMP ("docs-" + [guid]::NewGuid())
        New-ArquivoTeste "$docs\a.txt" | Out-Null
        cmd /c mklink /J "$script:raiz\j" "$docs" | Out-Null
        @(Get-ArquivoLimpeza -Pasta "$script:raiz\j").Count | Should -Be 0
        cmd /c rmdir "$script:raiz\j" | Out-Null
        Remove-Item $docs -Recurse -Force
    }

    It 'Exclui nomes informados' {
        New-ArquivoTeste "$script:raiz\desktop.ini" | Out-Null
        New-ArquivoTeste "$script:raiz\x.tmp" | Out-Null
        (@(Get-ArquivoLimpeza -Pasta $script:raiz -Excluir 'desktop.ini')).Name | Should -Be 'x.tmp'
    }
}

Describe 'Remove-ArquivoLimpeza' {
    BeforeEach {
        $script:raiz = Join-Path $env:TEMP ("teste-limpeza-" + [guid]::NewGuid())
        New-ArquivoTeste "$script:raiz\a\velho1.tmp" -IdadeDias 10 -Bytes 1MB | Out-Null
        New-ArquivoTeste "$script:raiz\velho2.tmp" -IdadeDias 10 -Bytes 1MB | Out-Null
        New-ArquivoTeste "$script:raiz\novo.tmp" | Out-Null
        (Get-Item "$script:raiz\a").LastWriteTime = (Get-Date).AddDays(-10)
    }
    AfterEach { cmd /c rmdir /s /q "$script:raiz" 2>$null }

    It 'Simulação lista quantidade e tamanho sem apagar' {
        $s = New-SessaoOtimizacao -Cliente T -Script Limpeza -Simular
        $l = Remove-ArquivoLimpeza -Sessao $s -Item L2 -Pasta $script:raiz -IdadeMinimaDias 7
        $l.Resultado | Should -Be 'Simulado'
        $l.ValorAnterior | Should -Be '2 arquivos, 2 MB'
        @(Get-ChildItem $script:raiz -Recurse -File).Count | Should -Be 3
    }

    It 'Apaga só os elegíveis, remove pasta vazia antiga e mantém a raiz' {
        $s = New-SessaoOtimizacao -Cliente T -Script Limpeza -Simular
        $s.Simular = $false
        New-Item -ItemType Directory "$script:raiz\recente" | Out-Null
        $l = Remove-ArquivoLimpeza -Sessao $s -Item L2 -Pasta $script:raiz -IdadeMinimaDias 7 -RemoverPastas
        $l.Resultado | Should -Be 'OK'
        $l.ValorNovo | Should -Be 'removidos 2 arquivos, 2 MB'
        Test-Path "$script:raiz\novo.tmp" | Should -BeTrue
        Test-Path "$script:raiz\a" | Should -BeFalse
        Test-Path "$script:raiz\recente" | Should -BeTrue
        Test-Path $script:raiz | Should -BeTrue
    }

    It 'Arquivo em uso é mantido, contado e o lote continua' {
        $s = New-SessaoOtimizacao -Cliente T -Script Limpeza -Simular
        $s.Simular = $false
        $fs = [IO.File]::Open("$script:raiz\velho2.tmp", 'Open', 'Read', 'None')
        try { $l = Remove-ArquivoLimpeza -Sessao $s -Item L2 -Pasta $script:raiz -IdadeMinimaDias 7 }
        finally { $fs.Dispose() }
        $l.ValorNovo | Should -Be 'removidos 1 arquivos, 1 MB'
        $l.Detalhe | Should -BeLike '1 em uso*'
        Test-Path "$script:raiz\velho2.tmp" | Should -BeTrue
    }

    It 'Segunda execução não encontra nada (idempotente)' {
        $s = New-SessaoOtimizacao -Cliente T -Script Limpeza -Simular
        $s.Simular = $false
        Remove-ArquivoLimpeza -Sessao $s -Item L2 -Pasta $script:raiz -IdadeMinimaDias 7 | Out-Null
        (Remove-ArquivoLimpeza -Sessao $s -Item L2 -Pasta $script:raiz -IdadeMinimaDias 7).Resultado | Should -Be 'JaAplicado'
    }

    It 'Pasta inexistente não é erro' {
        $s = New-SessaoOtimizacao -Cliente T -Script Limpeza -Simular
        (Remove-ArquivoLimpeza -Sessao $s -Item L1 -Pasta 'C:\nao\existe').Resultado | Should -Be 'JaAplicado'
    }
}

Describe 'Itens com dependências externas (mocks)' {
    It 'L3 pula navegador aberto' {
        Mock Get-Process -ParameterFilter { $Name -eq 'chrome' } { [pscustomobject]@{ Name = 'chrome' } }
        Mock Get-Process -ParameterFilter { $Name -eq 'msedge' } { }
        Mock Get-PastaPerfilUsuario { }
        $s = New-SessaoOtimizacao -Cliente T -Script Limpeza -Simular
        Invoke-L3 -Sessao $s
        ($s.Linhas | Where-Object Alvo -eq 'Chrome').Resultado | Should -Be 'Pulado'
    }

    It 'L8: HDD desfragmenta, mídia desconhecida é pulada, SSD habilita a tarefa desabilitada' {
        Mock Get-UnidadeFixa { 'C', 'D', 'E' }
        Mock Get-MidiaUnidade -ParameterFilter { $Letra -eq 'C' } { 'SSD' }
        Mock Get-MidiaUnidade -ParameterFilter { $Letra -eq 'D' } { 'HDD' }
        Mock Get-MidiaUnidade -ParameterFilter { $Letra -eq 'E' } { 'Unspecified' }
        Mock Optimize-Volume { }
        $script:estadoTarefa = 'Disabled'
        Mock Get-ScheduledTask { [pscustomobject]@{ State = $script:estadoTarefa } }
        Mock Enable-ScheduledTask { $script:estadoTarefa = 'Ready' }
        $s = New-SessaoOtimizacao -Cliente T -Script Limpeza -Simular
        $s.Simular = $false
        Invoke-L8 -Sessao $s
        Should -Invoke Optimize-Volume -Times 1 -ParameterFilter { $DriveLetter -eq 'D' -and $Defrag }
        ($s.Linhas | Where-Object Alvo -eq 'E:').Resultado | Should -Be 'Pulado'
        Should -Invoke Enable-ScheduledTask -Times 1
        ($s.Entradas | Where-Object Tipo -eq 'Tarefa').Estado | Should -Be 'Disabled'
    }

    It 'L6: cleanmgr que terminou sozinho não é encerrado' {
        Mock Start-Sleep { }
        Mock Stop-Process { }
        Wait-Cleanmgr -Processo ([pscustomobject]@{ HasExited = $true; Id = 999999 }) -Pasta 'C:\nao\existe' | Should -BeNullOrEmpty
        Should -Invoke Stop-Process -Times 0
    }

    It 'L6: cleanmgr ocioso após remover a pasta é encerrado com o motivo registrado' {
        Mock Start-Sleep { }
        Mock Get-CimInstance { }
        Mock Stop-Process { }
        $r = Wait-Cleanmgr -Processo ([pscustomobject]@{ HasExited = $false; Id = 999999 }) -Pasta 'C:\nao\existe' -SegundosApos 0
        $r | Should -BeLike '*falha conhecida*'
        Should -Invoke Stop-Process -Times 1 -ParameterFilter { $Id -eq 999999 }
    }

    It 'L6: pasta ainda presente no limite de tempo: encerra e informa o limite' {
        Mock Start-Sleep { }
        Mock Get-CimInstance { }
        Mock Stop-Process { }
        $r = Wait-Cleanmgr -Processo ([pscustomobject]@{ HasExited = $false; Id = 999999 }) -Pasta $env:windir -LimiteMinutos 0
        $r | Should -BeLike '*limite*'
    }

    It 'L8 nunca desfragmenta SSD' {
        Mock Get-UnidadeFixa { 'C' }
        Mock Get-MidiaUnidade { 'SSD' }
        Mock Optimize-Volume { }
        Mock Get-ScheduledTask { [pscustomobject]@{ State = 'Ready' } }
        $s = New-SessaoOtimizacao -Cliente T -Script Limpeza -Simular
        $s.Simular = $false
        Invoke-L8 -Sessao $s
        Should -Invoke Optimize-Volume -Times 0
    }
}

Describe 'L9 no registro real da VM: aplicar, idempotência, GPO e reversão' {
    BeforeAll {
        $script:sub = 'SOFTWARE\Policies\Microsoft\Windows\StorageSense'
        $script:chave = "HKLM:\$script:sub"
        Remove-Item $script:chave -Recurse -Force -ErrorAction SilentlyContinue
    }
    AfterAll { Remove-Item $script:chave -Recurse -Force -ErrorAction SilentlyContinue }

    It 'Aplica, relê, reaplica como JaAplicado e reverte removendo a chave criada' {
        $pasta = Join-Path $env:TEMP ('sessoes-' + [guid]::NewGuid())
        $s = New-SessaoOtimizacao -Cliente T -Script Limpeza -Raiz $pasta
        Invoke-L9 -Sessao $s
        (Get-ItemProperty $script:chave).AllowStorageSenseGlobal | Should -Be 1
        (Get-ItemProperty $script:chave).ConfigStorageSenseRecycleBinCleanupThreshold | Should -Be 0
        @($s.Linhas | Where-Object Resultado -eq 'OK').Count | Should -Be 4

        $s2 = New-SessaoOtimizacao -Cliente T -Script Limpeza -Raiz $pasta
        Invoke-L9 -Sessao $s2
        @($s2.Linhas | Where-Object Resultado -eq 'JaAplicado').Count | Should -Be 4

        $alvo = Get-SessaoParaReverter -Cliente T -Script Limpeza -Pasta $s.Pasta -Raiz $pasta
        $sr = New-SessaoOtimizacao -Cliente T -Script Limpeza -Raiz $pasta
        Invoke-Reversao -Sessao $sr -Alvo $alvo
        Test-Path $script:chave | Should -BeFalse
        Test-Path (Join-Path $s.Pasta 'revertido.txt') | Should -BeTrue
        Remove-Item $pasta -Recurse -Force
    }

    It 'Valor já definido com outro conteúdo (GPO) é pulado e preservado' {
        New-Item $script:chave -Force | Out-Null
        New-ItemProperty $script:chave -Name AllowStorageSenseGlobal -Value 0 -PropertyType DWord | Out-Null
        $s = New-SessaoOtimizacao -Cliente T -Script Limpeza -Simular
        $s.Simular = $false
        $s.Estado = $null
        Invoke-L9 -Sessao $s
        ($s.Linhas | Where-Object Alvo -like '*AllowStorageSenseGlobal').Resultado | Should -Be 'Pulado'
        (Get-ItemProperty $script:chave).AllowStorageSenseGlobal | Should -Be 0
        Remove-Item $script:chave -Recurse -Force
    }
}

Describe 'Invoke-Limpeza: bloqueios, backup e proteção de arquivos do usuário' {
    BeforeAll {
        $script:perfil = Join-Path $env:TEMP 'perfil-teste.psd1'
        "@{ Cliente = 'TesteVM'; Aplicar = @('L1','L2') }" | Out-File $script:perfil -Encoding UTF8
    }

    It 'Pré-checagem bloqueada: lança erro e não executa nenhum item' {
        Mock Test-PreCondicao { [pscustomobject]@{ Bloqueios = @('Execute como administrador.'); Avisos = @() } }
        Mock Invoke-L1 { }
        { Invoke-Limpeza -Perfil $script:perfil -IdadeMinimaDias 7 } | Should -Throw '*bloqueada*'
        Should -Invoke Invoke-L1 -Times 0
    }

    It 'Falha no ponto de restauração: lança erro e não executa nenhum item' {
        Mock Test-PreCondicao { [pscustomobject]@{ Bloqueios = @(); Avisos = @() } }
        Mock New-PontoRestauracao { throw 'Proteção do Sistema desativada' }
        Mock Invoke-L1 { }
        { Invoke-Limpeza -Perfil $script:perfil -IdadeMinimaDias 7 } | Should -Throw '*Backup falhou*'
        Should -Invoke Invoke-L1 -Times 0
    }

    It 'Execução real de L1 e L2 não altera Documentos, Desktop e Downloads do usuário' {
        $perfilUsuario = [Environment]::GetFolderPath('UserProfile')
        $pastas = 'Documents', 'Desktop', 'Downloads' | ForEach-Object { Join-Path $perfilUsuario $_ }
        foreach ($p in $pastas) { New-ArquivoTeste "$p\fixture-otimizacao.txt" -IdadeDias 60 | Out-Null }
        $antes = $pastas | ForEach-Object { Get-HashPasta $_ }
        New-ArquivoTeste "$env:TEMP\fixture-velho.tmp" -IdadeDias 30 | Out-Null
        Mock Test-PreCondicao { [pscustomobject]@{ Bloqueios = @(); Avisos = @() } }
        Mock New-PontoRestauracao { [pscustomobject]@{ SequenceNumber = 1 } }

        $s = Invoke-Limpeza -Perfil $script:perfil -IdadeMinimaDias 7

        ($pastas | ForEach-Object { Get-HashPasta $_ }) | Should -Be $antes
        Test-Path "$env:TEMP\fixture-velho.tmp" | Should -BeFalse
        @($s.Linhas | Where-Object Resultado -eq 'Falha').Count | Should -Be 0
        foreach ($p in $pastas) { Remove-Item "$p\fixture-otimizacao.txt" -Force }
    }
}
