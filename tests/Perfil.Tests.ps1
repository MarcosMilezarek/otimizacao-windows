# Perfil.ps1: geração do perfil do cliente pelo Menu. Roda no host: consultas ao sistema são simuladas por Mock e os
# arquivos ficam em TestDrive.
BeforeAll {
    . (Join-Path $PSScriptRoot '..\src\Perfil.ps1')
}

Describe 'Get-CatalogoPerfil' {
    BeforeAll { $script:Cat = @(Get-CatalogoPerfil) }

    It 'Tem os 40 itens na ordem de execução dos scripts' {
        $esperado = @('M1', 'M2', 'M3', 'M4', 'M8', 'A1', 'A2', 'A3', 'A4') + @(1..12 | ForEach-Object { "I$_" }) +
            @(1..10 | ForEach-Object { "V$_" }) + @(1..9 | ForEach-Object { "L$_" })
        ($script:Cat | ForEach-Object { $_.Id }) -join ',' | Should -Be ($esperado -join ',')
    }

    It 'Todo item tem texto e perda' {
        @($script:Cat | Where-Object { -not $_.Texto -or -not $_.Perda }).Count | Should -Be 0
    }

    It 'Itens de lista apontam para a chave de Opcoes do script' {
        $mapa = @{}
        $script:Cat | Where-Object { $_.Opcao } | ForEach-Object { $mapa[$_.Id] = $_.Opcao }
        $mapa.Count | Should -Be 5
        $mapa['I1'] | Should -Be 'I1Desabilitar'
        $mapa['I4'] | Should -Be 'I4NegarSegundoPlano'
        $mapa['I9'] | Should -Be 'I9Tarefas'
        $mapa['I10'] | Should -Be 'I10Servicos'
        $mapa['A2'] | Should -Be 'A2Remover'
    }

    It 'Só o A3 é informativo' {
        @($script:Cat | Where-Object { $_.Informativo } | ForEach-Object { $_.Id }) -join ',' | Should -Be 'A3'
    }

    It 'L4 a L7 e A1 trazem aviso de aprovação' {
        foreach ($id in 'L4', 'L5', 'L6', 'L7', 'A1') { ($script:Cat | Where-Object Id -EQ $id).Aviso | Should -Not -BeNullOrEmpty }
    }
}

Describe 'ConvertFrom-Selecao' {
    It 'Aceita IDs sem diferenciar maiúsculas, números, vírgulas e faixas' {
        (ConvertFrom-Selecao -Texto 'l1, 3 5-6' -Validos 'L1', 'L2', 'L3', 'L4', 'L5', 'L6') -join ',' | Should -Be 'L1,L3,L5,L6'
    }

    It 'Devolve na ordem dos válidos e sem repetição' {
        (ConvertFrom-Selecao -Texto 'L3 1 l3' -Validos 'L1', 'L2', 'L3') -join ',' | Should -Be 'L1,L3'
    }

    It 'Número fora da faixa lança ArgumentException com o token' {
        { ConvertFrom-Selecao -Texto '7' -Validos 'L1', 'L2' } | Should -Throw -ExceptionType ([ArgumentException]) -ExpectedMessage "*'7'*"
    }

    It 'ID desconhecido lança' {
        { ConvertFrom-Selecao -Texto 'X9' -Validos 'L1' } | Should -Throw -ExceptionType ([ArgumentException])
    }

    It 'Texto vazio devolve lista vazia' {
        @(ConvertFrom-Selecao -Texto '' -Validos 'L1').Count | Should -Be 0
    }
}

Describe 'Save-PerfilGerado' {
    BeforeEach {
        $script:Pasta = Join-Path $TestDrive ([guid]::NewGuid())
        $script:Dados = @{
            Cliente = 'Teste'; UsuarioSid = ''
            Aplicar = @('M8', 'I1', 'I10', 'A2')
            Opcoes  = @{ I1Desabilitar = @("O'Brien Tool"); I10Servicos = @{ 'Svc X' = 'Disabled' }; A2Remover = @('HP*'); M8Inicio = 7; M8Fim = 19 }
        }
    }

    It 'Grava e relê os mesmos valores, inclusive com apóstrofo' {
        $arq = Save-PerfilGerado -Dados $script:Dados -Pasta $script:Pasta
        $arq | Should -Be (Join-Path $script:Pasta 'Teste.psd1')
        $p = Import-PerfilCliente -Caminho $arq
        $p.Cliente | Should -Be 'Teste'
        $p.UsuarioSid | Should -Be ''
        $p.Aplicar -join ',' | Should -Be 'M8,I1,I10,A2'
        @($p.Pular).Count | Should -Be 0
        @($p.Opcoes.I1Desabilitar) -join '|' | Should -Be "O'Brien Tool"
        $p.Opcoes.I10Servicos['Svc X'] | Should -Be 'Disabled'
        @($p.Opcoes.A2Remover) -join '|' | Should -Be 'HP*'
        $p.Opcoes.M8Inicio | Should -Be 7
        $p.Opcoes.M8Fim | Should -Be 19
        foreach ($c in 'Inicializacao', 'Servicos', 'Tarefas', 'Aplicativos') { $p.Protegidos.ContainsKey($c) | Should -BeTrue }
    }

    It 'Grava em UTF-8 com BOM' {
        $arq = Save-PerfilGerado -Dados $script:Dados -Pasta $script:Pasta
        $b = [IO.File]::ReadAllBytes($arq)
        '{0:X2}{1:X2}{2:X2}' -f $b[0], $b[1], $b[2] | Should -Be 'EFBBBF'
    }

    It 'Não sobrescreve sem -Force' {
        Save-PerfilGerado -Dados $script:Dados -Pasta $script:Pasta | Out-Null
        { Save-PerfilGerado -Dados $script:Dados -Pasta $script:Pasta } | Should -Throw
        $script:Dados.Aplicar = @('L1')
        $arq = Save-PerfilGerado -Dados $script:Dados -Pasta $script:Pasta -Force
        (Import-PerfilCliente -Caminho $arq).Aplicar -join ',' | Should -Be 'L1'
    }

    It 'Cliente inválido lança e não deixa arquivo' {
        $script:Dados.Cliente = 'a b'
        { Save-PerfilGerado -Dados $script:Dados -Pasta $script:Pasta } | Should -Throw
        @(Get-ChildItem -LiteralPath $script:Pasta -ErrorAction SilentlyContinue).Count | Should -Be 0
    }
}
