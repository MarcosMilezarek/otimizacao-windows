# Iniciar.ps1: lançador do comando irm | iex. Roda no host: downloads simulados por Mock, arquivos em TestDrive.
BeforeAll {
    $script:Fonte = Join-Path $PSScriptRoot '..\Iniciar.ps1'
    $OtimizacaoIniciarSemExecutar = $true
    . $script:Fonte

    $script:Commit = 'a' * 40
    $script:Conteudo = [ordered]@{ 'src/Menu.ps1' = 'menu'; 'src/Otimizacao.Comum.psm1' = 'comum'; 'perfis/exemplo.psd1' = '@{}' }
    function Get-HashTexto([string]$Texto) {
        $sha = [Security.Cryptography.SHA256]::Create()
        -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Texto)) | ForEach-Object { $_.ToString('X2') })
    }
    function New-Tabela {
        $t = [ordered]@{}
        foreach ($k in $script:Conteudo.Keys) { $t[$k] = Get-HashTexto $script:Conteudo[$k] }
        $t
    }
}

Describe 'Install-ProjetoIniciar' {
    BeforeEach {
        $script:Raiz = Join-Path $TestDrive ([guid]::NewGuid())
        $script:Servidor = [ordered]@{}
        foreach ($k in $script:Conteudo.Keys) { $script:Servidor[$k] = $script:Conteudo[$k] }
        Mock Invoke-WebRequest {
            $rel = $Uri -replace '^https://raw\.githubusercontent\.com/u/r/a{40}/', ''
            if (-not $script:Servidor.Contains($rel)) { throw "404 $rel" }
            [IO.File]::WriteAllText($OutFile, $script:Servidor[$rel], (New-Object Text.UTF8Encoding $false))
        }
    }

    It 'Baixa e confere todos os arquivos para app\sha7' {
        $p = Install-ProjetoIniciar -Raiz $script:Raiz -Repo 'u/r' -Commit $script:Commit -Arquivos (New-Tabela)
        $p | Should -Be (Join-Path $script:Raiz 'app\aaaaaaa')
        Get-Content -LiteralPath (Join-Path $p 'src\Menu.ps1') -Raw | Should -Be 'menu'
        Test-Path -LiteralPath (Join-Path $p 'perfis\exemplo.psd1') | Should -BeTrue
        @(Get-ChildItem -LiteralPath (Join-Path $script:Raiz 'app') -Filter '.baixando-*' -Force).Count | Should -Be 0
    }

    It 'Hash divergente aborta com o nome do arquivo e não deixa pasta' {
        $script:Servidor['src/Otimizacao.Comum.psm1'] = 'adulterado'
        { Install-ProjetoIniciar -Raiz $script:Raiz -Repo 'u/r' -Commit $script:Commit -Arquivos (New-Tabela) } | Should -Throw '*src/Otimizacao.Comum.psm1*'
        Test-Path -LiteralPath (Join-Path $script:Raiz 'app\aaaaaaa') | Should -BeFalse
        @(Get-ChildItem -LiteralPath (Join-Path $script:Raiz 'app') -Force -ErrorAction SilentlyContinue).Count | Should -Be 0
    }

    It 'Falha de download aborta e limpa' {
        $script:Servidor.Remove('src/Menu.ps1')
        { Install-ProjetoIniciar -Raiz $script:Raiz -Repo 'u/r' -Commit $script:Commit -Arquivos (New-Tabela) } | Should -Throw '*src/Menu.ps1*'
        @(Get-ChildItem -LiteralPath (Join-Path $script:Raiz 'app') -Force -ErrorAction SilentlyContinue).Count | Should -Be 0
    }

    It 'Pasta já íntegra não baixa de novo' {
        Install-ProjetoIniciar -Raiz $script:Raiz -Repo 'u/r' -Commit $script:Commit -Arquivos (New-Tabela) | Out-Null
        Install-ProjetoIniciar -Raiz $script:Raiz -Repo 'u/r' -Commit $script:Commit -Arquivos (New-Tabela) | Out-Null
        Should -Invoke Invoke-WebRequest -Times 3 -Exactly
    }

    It 'Pasta com arquivo alterado é baixada de novo' {
        $p = Install-ProjetoIniciar -Raiz $script:Raiz -Repo 'u/r' -Commit $script:Commit -Arquivos (New-Tabela)
        Set-Content -LiteralPath (Join-Path $p 'src\Menu.ps1') -Value 'mexido'
        $p = Install-ProjetoIniciar -Raiz $script:Raiz -Repo 'u/r' -Commit $script:Commit -Arquivos (New-Tabela)
        Get-Content -LiteralPath (Join-Path $p 'src\Menu.ps1') -Raw | Should -Be 'menu'
        Test-PastaIntegra -Pasta $p -Arquivos (New-Tabela) | Should -BeTrue
    }
}

Describe 'Start-Iniciar' {
    It 'Sem administrador aborta antes de baixar' {
        Mock Test-AdministradorIniciar { $false }
        Mock Invoke-WebRequest { }
        { Start-Iniciar } | Should -Throw '*administrador*'
        Should -Invoke Invoke-WebRequest -Times 0
    }

    It 'Abre o Menu da pasta instalada em processo novo' {
        Mock Test-AdministradorIniciar { $true }
        Mock Install-ProjetoIniciar { 'C:\X\app\aaaaaaa' }
        Mock Set-AcessoRestritoIniciar { }
        Mock Start-Process { }
        Start-Iniciar
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -like '*-ExecutionPolicy Bypass -File "C:\X\app\aaaaaaa\src\Menu.ps1"*' }
    }
}

Describe 'Arquivo Iniciar.ps1' {
    It 'É ASCII puro e sem BOM (iex falha com BOM)' {
        @([IO.File]::ReadAllBytes($script:Fonte) | Where-Object { $_ -gt 0x7F }).Count | Should -Be 0
    }

    It 'Tabela embutida cobre src e o exemplo, com SHA256 de 64 hex' {
        $script:ArquivosIniciar.Keys | Should -Contain 'src/Menu.ps1'
        $script:ArquivosIniciar.Keys | Should -Contain 'perfis/exemplo.psd1'
        @($script:ArquivosIniciar.Values | Where-Object { $_ -notmatch '^[0-9A-F]{64}$' }).Count | Should -Be 0
        $script:CommitIniciar | Should -Match '^[0-9a-f]{40}$'
    }

    It 'Não usa exit (fecharia a janela de quem executa via iex)' {
        Get-Content -LiteralPath $script:Fonte | Where-Object { $_ -match '^\s*exit\b' } | Should -BeNullOrEmpty
    }
}
