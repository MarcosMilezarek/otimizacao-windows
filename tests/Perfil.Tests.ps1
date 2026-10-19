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

    It 'Só os itens da Manutencao têm quando usar, o que corrige e fonte' {
        @($script:Cat | Where-Object { $_.Quando -and $_.Corrige -and $_.Fonte } | ForEach-Object { $_.Id }) -join ',' | Should -Be 'M1,M2,M3,M4,M8'
        @($script:Cat | Where-Object { $_.Script -ne 'Manutencao' -and ($_.Quando -or $_.Corrige -or $_.Fonte) }).Count | Should -Be 0
    }
}

Describe 'Pré-seleção e validações do Novo perfil' {
    It 'Pré-seleciona todos, menos a Manutencao, o A3, o I3 e o I9' {
        $fora = @(Get-CatalogoPerfil | Where-Object { -not (Test-PreSelecionado -Item $_) } | ForEach-Object { $_.Id })
        $fora -join ',' | Should -Be 'M1,M2,M3,M4,M8,A3,I3,I9'
    }

    It 'Nome do cliente: letras, números, ponto, hífen e sublinhado, até 60' {
        Test-NomeCliente 'Cliente_1.a-b' | Should -BeTrue
        Test-NomeCliente 'a b' | Should -BeFalse
        Test-NomeCliente '' | Should -BeFalse
        Test-NomeCliente ('x' * 61) | Should -BeFalse
    }

    It 'Horário do M8: 0 a 23 e intervalo de 1 a 18 h, inclusive passando da meia-noite' {
        Test-HorarioM8 -Inicio 8 -Fim 17 | Should -BeTrue
        Test-HorarioM8 -Inicio 22 -Fim 6 | Should -BeTrue
        Test-HorarioM8 -Inicio 7 -Fim 7 | Should -BeFalse
        Test-HorarioM8 -Inicio 0 -Fim 19 | Should -BeFalse
        Test-HorarioM8 -Inicio 8 -Fim 24 | Should -BeFalse
    }
}

Describe 'New-DadosPerfil' {
    It 'Itens na ordem do catálogo, sem o informativo A3' {
        $r = New-DadosPerfil -Cliente 'C' -Marcados 'L1', 'A3', 'M8', 'A4' -Opcoes @{ M8Inicio = 7; M8Fim = 19 }
        $r.Dados.Aplicar -join ',' | Should -Be 'M8,A4,L1'
        $r.Dados.Opcoes.M8Inicio | Should -Be 7
        $r.Dados.UsuarioSid | Should -Be ''
    }

    It 'Item de lista sem escolha sai de Aplicar e vai para Desmarcados' {
        $r = New-DadosPerfil -Cliente 'C' -Marcados 'I1', 'I2', 'I10' -Escolhas @{ I1 = @('X Agent'); I10 = @{} }
        $r.Dados.Aplicar -join ',' | Should -Be 'I1,I2'
        $r.Desmarcados -join ',' | Should -Be 'I10'
        @($r.Dados.Opcoes.I1Desabilitar) -join '|' | Should -Be 'X Agent'
    }

    It 'I10 guarda a tabela serviço = Manual ou Disabled; A2 guarda os Ids' {
        $r = New-DadosPerfil -Cliente 'C' -Marcados 'I10', 'A2' -Escolhas @{ I10 = @{ 'Svc X' = 'Disabled' }; A2 = @('AD2F1837.HPPrinterControl') }
        $r.Dados.Opcoes.I10Servicos['Svc X'] | Should -Be 'Disabled'
        @($r.Dados.Opcoes.A2Remover) -join '|' | Should -Be 'AD2F1837.HPPrinterControl'
    }

    It 'Opções só dos itens marcados' {
        $r = New-DadosPerfil -Cliente 'C' -Marcados 'M1', 'L1' -Opcoes @{ M1Reparar = $true; M2Reparar = $true; V5DesligarInicializacaoRapida = $true }
        $r.Dados.Opcoes.ContainsKey('M1Reparar') | Should -BeTrue
        $r.Dados.Opcoes.ContainsKey('M2Reparar') | Should -BeFalse
        $r.Dados.Opcoes.ContainsKey('V5DesligarInicializacaoRapida') | Should -BeFalse
    }

    It 'Usuário escolhido vai para UsuarioSid e o resultado grava e relê' {
        $r = New-DadosPerfil -Cliente 'ClienteB' -UsuarioSid 'S-1-5-21-1-2-3-1001' -Marcados 'M3'
        $arq = Save-PerfilGerado -Dados $r.Dados -Pasta (Join-Path $TestDrive ([guid]::NewGuid()))
        $p = Import-PerfilCliente -Caminho $arq
        $p.UsuarioSid | Should -Be 'S-1-5-21-1-2-3-1001'
        $p.Aplicar -join ',' | Should -Be 'M3'
    }

    It 'Resumo mostra o nome do programa escolhido no A2, as opções e os desmarcados' {
        $r = New-DadosPerfil -Cliente 'K' -Marcados 'A2', 'I1', 'M8' -Escolhas @{ A2 = @('AD2F1837.HPPrinterControl') } -Opcoes @{ M8Inicio = 8; M8Fim = 17 }
        $texto = (Get-ResumoPerfil -Dados $r.Dados -Usuario 'PC\cliente' -Rotulos @{ A2 = @('HP Smart 1  [HP Inc., Appx]') } -Desmarcados $r.Desmarcados) -join "`n"
        $texto | Should -Match '-> HP Smart'
        $texto | Should -Match 'M8Inicio = 8'
        $texto | Should -Match 'Desmarcados por nada escolhido na lista: I1'
    }
}

Describe 'Listas da máquina' {
    BeforeAll { $script:Alvo = [pscustomobject]@{ Sid = 'S-1-5-21-1-2-3-1001'; Perfil = 'C:\Users\cliente' } }

    It 'I1 mostra só entradas que não são componentes do Windows' {
        Mock Invoke-NoHiveUsuario { & $ScriptBlock 'Registry::HKEY_USERS\S-1-5-21-1-2-3-1001' }
        Mock Get-FonteInicializacao {
            if ($Escopo -eq 'Maquina') {
                [pscustomobject]@{ Origem = 'Maquina\Run'; Nome = 'SecurityHealth'; Comando = "$env:windir\System32\SecurityHealthSystray.exe" }
                [pscustomobject]@{ Origem = 'Maquina\Run'; Nome = 'X Agent'; Comando = '"C:\Program Files\X\x.exe" /min' }
            }
            else { [pscustomobject]@{ Origem = 'Usuario\Run'; Nome = 'X Agent'; Comando = '"C:\Program Files\X\x.exe" /min' } }
        }
        $r = @(Get-CandidatoI1 -Alvo $script:Alvo)
        ($r | ForEach-Object { $_.Nome }) -join '|' | Should -Be 'X Agent'
        Should -Invoke Invoke-NoHiveUsuario -Times 1 -Exactly -ParameterFilter { $Sid -eq 'S-1-5-21-1-2-3-1001' -and $Perfil -eq 'C:\Users\cliente' }
    }

    It 'I4 descarta frameworks, pacotes do sistema e PFN inválido' {
        Mock Get-AppxPackage {
            [pscustomobject]@{ Name = 'Spotify'; PackageFamilyName = 'SpotifyAB.SpotifyMusic_zpdnekdrzrea0'; IsFramework = $false; IsResourcePackage = $false; NonRemovable = $false; SignatureKind = 'Store' }
            [pscustomobject]@{ Name = 'Fw'; PackageFamilyName = 'Microsoft.VCLibs_8wekyb3d8bbwe'; IsFramework = $true; IsResourcePackage = $false; NonRemovable = $false; SignatureKind = 'Store' }
            [pscustomobject]@{ Name = 'Sis'; PackageFamilyName = 'Microsoft.Windows.ShellExperienceHost_cw5n1h2txyewy'; IsFramework = $false; IsResourcePackage = $false; NonRemovable = $true; SignatureKind = 'System' }
            [pscustomobject]@{ Name = 'Ruim'; PackageFamilyName = 'nome invalido'; IsFramework = $false; IsResourcePackage = $false; NonRemovable = $false; SignatureKind = 'Store' }
        }
        Mock Get-NomeExibicaoAppx { [pscustomobject]@{ Nome = "App $($Pacote.Name)"; Fabricante = 'X' } }
        $r = @(Get-CandidatoI4 -Alvo $script:Alvo)
        ($r | ForEach-Object { $_.Pfn }) -join '|' | Should -Be 'SpotifyAB.SpotifyMusic_zpdnekdrzrea0'
        $r[0].Nome | Should -Be 'App Spotify'
        Should -Invoke Get-AppxPackage -ParameterFilter { $User -eq 'S-1-5-21-1-2-3-1001' }
    }

    It 'I9 mostra só tarefas fora de \Microsoft\ e não desabilitadas' {
        Mock Get-ScheduledTask {
            $acao = @([pscustomobject]@{ Execute = 'C:\Program Files\F\upd.exe' })
            [pscustomobject]@{ TaskPath = '\Microsoft\Windows\'; TaskName = 'A'; State = 'Ready'; Actions = $acao }
            [pscustomobject]@{ TaskPath = '\Fabricante\'; TaskName = 'Atualizar'; State = 'Ready'; Actions = $acao }
            [pscustomobject]@{ TaskPath = '\Outra\'; TaskName = 'B'; State = 'Disabled'; Actions = $acao }
        }
        Mock Get-EmpresaExecutavel { 'F SA' }
        (@(Get-CandidatoI9) | ForEach-Object { $_.Caminho }) -join '|' | Should -Be '\Fabricante\Atualizar'
    }

    It 'I10 mostra só serviços de terceiros com início automático ou manual' {
        Mock Get-Service {
            'Win', 'Drv', 'Boot', 'Terceiro', 'Desativado' | ForEach-Object { [pscustomobject]@{ Name = $_; DisplayName = "Serviço $_" } }
        }
        Mock Get-InicioServico {
            switch ($Nome) {
                'Win' { [pscustomobject]@{ Start = 2; Atrasado = $false; Tipo = 0x10; ImagePath = '%SystemRoot%\System32\svchost.exe -k netsvcs' } }
                'Drv' { [pscustomobject]@{ Start = 3; Atrasado = $false; Tipo = 0x1; ImagePath = 'C:\Program Files\D\d.sys' } }
                'Boot' { [pscustomobject]@{ Start = 1; Atrasado = $false; Tipo = 0x10; ImagePath = 'C:\Program Files\B\b.exe' } }
                'Terceiro' { [pscustomobject]@{ Start = 2; Atrasado = $false; Tipo = 0x10; ImagePath = '"C:\Program Files\T\t.exe"' } }
                'Desativado' { [pscustomobject]@{ Start = 4; Atrasado = $false; Tipo = 0x10; ImagePath = 'C:\Program Files\Z\z.exe' } }
            }
        }
        $r = @(Get-CandidatoI10)
        ($r | ForEach-Object { $_.Nome }) -join '|' | Should -Be 'Terceiro'
        $r[0].Exibicao | Should -Be 'Serviço Terceiro'
    }

    It 'I10 esconde serviços da Microsoft fora de %windir% (Defender é intocável)' {
        Mock Get-Service { 'WinDefend', 'Terceiro' | ForEach-Object { [pscustomobject]@{ Name = $_; DisplayName = $_ } } }
        Mock Get-InicioServico {
            $img = if ($Nome -eq 'WinDefend') { '"C:\ProgramData\Microsoft\Windows Defender\platform\4.18\MsMpEng.exe"' } else { 'C:\Program Files\T\t.exe' }
            [pscustomobject]@{ Start = 2; Atrasado = $false; Tipo = 0x10; ImagePath = $img }
        }
        Mock Get-EmpresaExecutavel { if ($Caminho -like '*MsMpEng.exe') { 'Microsoft Corporation' } else { 'T Ltda' } }
        (@(Get-CandidatoI10) | ForEach-Object { $_.Nome }) -join '|' | Should -Be 'Terceiro'
    }

    It 'I9 esconde tarefas que executam programa do Windows ou da Microsoft' {
        Mock Get-ScheduledTask {
            [pscustomobject]@{ TaskPath = '\'; TaskName = 'CreateExplorerShellUnelevatedTask'; State = 'Ready'; Actions = @([pscustomobject]@{ Execute = 'C:\Windows\explorer.exe' }) }
            [pscustomobject]@{ TaskPath = '\'; TaskName = 'MicrosoftEdgeUpdateTaskMachineCore'; State = 'Ready'; Actions = @([pscustomobject]@{ Execute = 'C:\Program Files (x86)\Microsoft\EdgeUpdate\MicrosoftEdgeUpdate.exe' }) }
            [pscustomobject]@{ TaskPath = '\Fabricante\'; TaskName = 'Atualizar'; State = 'Ready'; Actions = @([pscustomobject]@{ Execute = 'C:\Program Files\F\upd.exe' }) }
            [pscustomobject]@{ TaskPath = '\SoftLanding\'; TaskName = 'Com'; State = 'Ready'; Actions = @([pscustomobject]@{ ClassId = '{00000000-0000-0000-0000-000000000000}' }) }
        }
        Mock Get-EmpresaExecutavel { if ($Caminho -like '*EdgeUpdate*') { 'Microsoft Corporation' } else { 'F SA' } }
        (@(Get-CandidatoI9) | ForEach-Object { $_.Caminho }) -join '|' | Should -Be '\Fabricante\Atualizar'
    }

    It 'A2 esconde ferramentas de driver e programas da Microsoft' {
        Mock Get-ProgramaMaquina {
            [pscustomobject]@{ Nome = 'Dell SupportAssist'; Fabricante = 'Dell Inc.'; Versao = '4'; Tipo = 'MSI'; Id = '{11111111-1111-1111-1111-111111111111}' }
            [pscustomobject]@{ Nome = 'Microsoft Visual C++'; Fabricante = 'Microsoft Corporation'; Versao = '14'; Tipo = 'MSI'; Id = '{22222222-2222-2222-2222-222222222222}' }
            [pscustomobject]@{ Nome = 'HP Smart'; Fabricante = 'HP Inc.'; Versao = '1'; Tipo = 'Appx'; Id = 'AD2F1837.HPPrinterControl' }
        }
        (@(Get-CandidatoA2) | ForEach-Object { $_.Nome }) -join '|' | Should -Be 'HP Smart'
    }

    It 'A2 esconde Appx do sistema ou não removível e programa sem fabricante com nome Microsoft' {
        Mock Get-ProgramaMaquina {
            [pscustomobject]@{ Nome = 'Email, telefone ou Skype'; Fabricante = 'Atribuída por sua organização'; Versao = '1'; Tipo = 'Appx'; Id = 'Microsoft.AAD.BrokerPlugin' }
            [pscustomobject]@{ Nome = 'Microsoft Windows Application Compatibility Fix Database'; Fabricante = ''; Versao = '1'; Tipo = 'EXE'; Id = 'CompatFix' }
            [pscustomobject]@{ Nome = 'HP Smart'; Fabricante = 'HP Inc.'; Versao = '1'; Tipo = 'Appx'; Id = 'AD2F1837.HPPrinterControl' }
        }
        Mock Get-AppxPackage {
            [pscustomobject]@{ Name = 'Microsoft.AAD.BrokerPlugin'; NonRemovable = $true; SignatureKind = 'System' }
            [pscustomobject]@{ Name = 'AD2F1837.HPPrinterControl'; NonRemovable = $false; SignatureKind = 'Store' }
        }
        (@(Get-CandidatoA2) | ForEach-Object { $_.Nome }) -join '|' | Should -Be 'HP Smart'
    }
}

# Janelas reais (WinForms) conduzidas por um temporizador na mesma thread: ele dispara dentro do laço da janela modal,
# preenche os campos e clica nos botões. Só leitura do sistema (listas por Mock); o perfil é gravado em TestDrive.
# Pulados fora de sessão interativa (PowerShell Direct na VM): o WinForms recusa ShowDialog sem UserInteractive.
Describe 'Janelas do Novo perfil e do Menu' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\src\Menu.ps1')
        Initialize-Interface

        function Get-ControleJanela {
            param($Raiz, [scriptblock]$Filtro)
            foreach ($c in $Raiz.Controls) { if (& $Filtro $c) { $c }; Get-ControleJanela -Raiz $c -Filtro $Filtro }
        }

        function Invoke-ComTemporizador {
            <# Executa a janela aberta por Abrir; a cada tique chama o passo seguinte com a janela do Titulo. Fecha tudo se passar do limite. #>
            # Estado em $script: com nomes do teste: o tique roda dentro da janela, e por escopo dinâmico um nome local
            # (como $passos ou $f) acharia a variável da janela.
            param([string]$Titulo, [scriptblock[]]$Passos, [scriptblock]$Abrir)
            $script:TesteTitulo = $Titulo
            $script:TestePassos = $Passos
            $script:Indice = 0
            $script:Tiques = 0
            $script:Falha = $null
            $script:TesteRelogio = New-Object Windows.Forms.Timer; $script:TesteRelogio.Interval = 300
            $script:TesteRelogio.Add_Tick({
                    $script:Tiques++
                    $janela = @([Windows.Forms.Application]::OpenForms | Where-Object { $_.Text -eq $script:TesteTitulo })[0]
                    if ($script:Tiques -gt 60) { $script:TesteRelogio.Stop(); foreach ($x in @([Windows.Forms.Application]::OpenForms)) { $x.Dispose() }; return }
                    if (-not $janela -or $script:Indice -ge $script:TestePassos.Count) { return }
                    try { & $script:TestePassos[$script:Indice] $janela } catch { $script:Falha = $_.Exception.Message; $script:TesteRelogio.Stop(); $janela.Dispose(); return }
                    $script:Indice++
                })
            $script:TesteRelogio.Start()
            try { & $Abrir } finally { $script:TesteRelogio.Stop(); $script:TesteRelogio.Dispose() }
        }

        function Invoke-Botao {
            param($Janela, [string]$Texto)
            @(Get-ControleJanela -Raiz $Janela -Filtro { param($c) $c -is [Windows.Forms.Button] -and $c.Text -eq $Texto })[0].PerformClick()
        }
    }

    BeforeEach {
        $script:Pasta = Join-Path $TestDrive ([guid]::NewGuid())
        Mock Get-UsuarioLocal { [pscustomobject]@{ Sid = 'S-1-5-21-1-2-3-1001'; Nome = 'PC\cliente'; Perfil = 'C:\Users\cliente' } }
        Mock Get-UsuarioAlvo { [pscustomobject]@{ Sid = 'S-1-5-21-1-2-3-1001'; Perfil = 'C:\Users\cliente' } }
        Mock Get-CandidatoI1 { [pscustomobject]@{ Nome = 'X Agent'; Origem = 'Maquina\Run'; Comando = 'x.exe' }, [pscustomobject]@{ Nome = 'Y'; Origem = 'Usuario\Run'; Comando = 'y.exe' } }
        Mock Get-CandidatoI4 { }
        Mock Get-CandidatoI10 { [pscustomobject]@{ Nome = 'Svc X'; Exibicao = 'Serviço X'; Inicio = 'Automático' } }
        Mock Get-CandidatoA2 { throw 'leitura falhou' }
    }

    It 'Novo perfil: pré-seleção, listas, horário do M8 e gravação' -Skip:(-not [Environment]::UserInteractive) {
        $script:Visto = @{}
        $passos = @(
            { param($f) @(Get-ControleJanela $f { param($c) $c.Name -eq 'Cliente' })[0].Text = 'ClienteGui'; Invoke-Botao $f 'Avançar' }
            {
                param($f)
                $cat = @(Get-ControleJanela $f { param($c) $c.Name -eq 'Catalogo' })[0]
                $script:Visto.PreMarcados = @($cat.CheckedItems | ForEach-Object { $_.Text })
                # Marca o M8 e tenta marcar o A3 (informativo, não deve ficar marcado).
                foreach ($it in $cat.Items) { if ($it.Text -in 'M8', 'A3') { $it.Checked = $true } }
                $script:Visto.A3 = ($cat.Items | Where-Object Text -EQ 'A3').Checked
                Invoke-Botao $f 'Avançar'
            }
            {
                param($f)
                $w = $f.Tag
                $script:Visto.Abas = @($w.Abas.Keys | Sort-Object)
                $w.Abas['I1'].Grade.Rows[0].Cells[0].Value = $true
                $g10 = $w.Abas['I10'].Grade
                $g10.Rows[0].Cells[0].Value = $true
                $g10.Rows[0].Cells[2].Value = 'Desativado'
                $script:Visto.SemGradeA2 = -not $w.Abas['A2'].Grade
                Invoke-Botao $f 'Avançar'
            }
            {
                param($f)
                @(Get-ControleJanela $f { param($c) $c.Name -eq 'M8Inicio' })[0].Value = 7
                @(Get-ControleJanela $f { param($c) $c.Name -eq 'M8Fim' })[0].Value = 19
                Invoke-Botao $f 'Avançar'
            }
            { param($f) $script:Visto.Resumo = @(Get-ControleJanela $f { param($c) $c.Name -eq 'Resumo' })[0].Text; Invoke-Botao $f 'Gravar perfil' }
        )
        $script:Arquivo = $null
        Invoke-ComTemporizador -Titulo 'Novo perfil' -Passos $passos -Abrir { $script:Arquivo = Show-JanelaNovoPerfil -Pasta $script:Pasta }
        $script:Falha | Should -BeNullOrEmpty
        $script:Visto.PreMarcados -join ',' | Should -Be (@(Get-CatalogoPerfil | Where-Object { Test-PreSelecionado -Item $_ } | ForEach-Object { $_.Id }) -join ',')
        $script:Visto.A3 | Should -BeFalse
        $script:Visto.Abas -join ',' | Should -Be 'A2,I1,I10,I4'
        $script:Visto.SemGradeA2 | Should -BeTrue
        $script:Visto.Resumo | Should -Match 'Desmarcados por nada escolhido na lista: A2, I4'
        $script:Arquivo | Should -Be (Join-Path $script:Pasta 'ClienteGui.psd1')
        $p = Import-PerfilCliente -Caminho $script:Arquivo
        $p.Aplicar -contains 'M8' | Should -BeTrue
        foreach ($id in 'A2', 'A3', 'I3', 'I4', 'I9', 'M1') { $p.Aplicar -contains $id | Should -BeFalse }
        @($p.Opcoes.I1Desabilitar) -join '|' | Should -Be 'X Agent'
        $p.Opcoes.I10Servicos['Svc X'] | Should -Be 'Disabled'
        $p.Opcoes.M8Inicio | Should -Be 7
        $p.Opcoes.M8Fim | Should -Be 19
        $p.Opcoes.V5DesligarInicializacaoRapida | Should -BeFalse
        $p.UsuarioSid | Should -Be ''
    }

    It 'Novo perfil: nome inválido não avança e nada é gravado' -Skip:(-not [Environment]::UserInteractive) {
        $script:Visto = @{}
        $passos = @(
            { param($f) @(Get-ControleJanela $f { param($c) $c.Name -eq 'Cliente' })[0].Text = 'a b'; Invoke-Botao $f 'Avançar' }
            { param($f) $script:Visto.Passo = $f.Tag.Passo; $f.DialogResult = 'OK' }
        )
        Invoke-ComTemporizador -Titulo 'Novo perfil' -Passos $passos -Abrir { $script:Arquivo = Show-JanelaNovoPerfil -Pasta $script:Pasta }
        $script:Visto.Passo | Should -Be 0
        $script:Arquivo | Should -BeNullOrEmpty
        Test-Path -LiteralPath $script:Pasta | Should -BeFalse
    }

    It 'Menu: lista os perfis e mostra os itens do escolhido, sem executar nada' -Skip:(-not [Environment]::UserInteractive) {
        $gerados = Join-Path $TestDrive ([guid]::NewGuid()); $projeto = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory -Path $gerados, $projeto | Out-Null
        [IO.File]::WriteAllText((Join-Path $gerados 'A.psd1'), "@{ Cliente = 'A'; UsuarioSid = ''; Aplicar = @('M3', 'L1', 'V2'); Pular = @('V2') }", (New-Object Text.UTF8Encoding $true))
        [IO.File]::WriteAllText((Join-Path $projeto 'exemplo.psd1'), "@{ Cliente = 'E' }", (New-Object Text.UTF8Encoding $true))
        Mock Get-PastaPerfil { $gerados, $projeto }
        Mock Start-ProcessoScript { throw 'não deveria executar' }
        $script:Visto = @{}
        $passos = @(
            {
                param($f)
                $lst = @(Get-ControleJanela $f { param($c) $c.Name -eq 'Perfis' })[0]
                $script:Visto.Perfis = @($lst.Items)
                $lst.SelectedIndex = 0
                $script:Visto.Itens = @(@(Get-ControleJanela $f { param($c) $c -is [Windows.Forms.ListView] })[0].Items | ForEach-Object { $_.Text })
                $script:Visto.Simular = @(Get-ControleJanela $f { param($c) $c -is [Windows.Forms.Button] -and $c.Text -eq 'Simular' })[0].Enabled
                $f.Close()
            }
        )
        Invoke-ComTemporizador -Titulo 'Otimização' -Passos $passos -Abrir { $script:Iniciou = Show-JanelaMenu }
        $script:Falha | Should -BeNullOrEmpty
        $script:Visto.Perfis -join ',' | Should -Be 'A'
        $script:Visto.Itens -join ',' | Should -Be 'M3,L1'
        $script:Visto.Simular | Should -BeTrue
        $script:Iniciou | Should -BeFalse
        Should -Invoke Start-ProcessoScript -Times 0
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

    It 'Apóstrofo tipográfico (U+2019) relê idêntico' {
        $nome = "Mike$([char]0x2019)s Tool"
        $script:Dados.Opcoes.I1Desabilitar = @($nome)
        $arq = Save-PerfilGerado -Dados $script:Dados -Pasta $script:Pasta
        @((Import-PerfilCliente -Caminho $arq).Opcoes.I1Desabilitar) -join '|' | Should -Be $nome
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
