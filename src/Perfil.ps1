<#
.SYNOPSIS
    Geração do perfil do cliente pelo Menu (opção Novo perfil). Carregado pelo Menu com dot-source; não executa nada sozinho.

.DESCRIPTION
    Pergunta o cliente e o usuário alvo, mostra o catálogo por script sem nada marcado, lê da máquina as listas dos itens
    I1, I4, I9, I10 e A2 com o mesmo filtro que o script aplica, pergunta as opções só dos itens marcados, mostra o
    resumo e grava C:\ProgramData\Otimizacao\perfis\<Cliente>.psd1 (UTF-8 com BOM), relido por Import-PerfilCliente.

    O que altera: só grava o arquivo do perfil. O que se perde: nada. Reversão: apagar o arquivo.
    Nenhum dado sai da máquina.
#>

Import-Module (Join-Path $PSScriptRoot 'Otimizacao.Comum.psm1') -Force

#region Catálogo e gravação

# Textos resumidos do cabeçalho de ajuda de cada script (fonte única: o script; nada além do que está lá).
$script:CatalogoPerfil = @(
    @{ Id = 'M1'; Script = 'Manutencao'; Texto = 'Verifica a imagem do Windows (DISM ScanHealth).'; Perda = 'Nada; com reparo aprovado, baixa arquivos pelo Windows Update e leva vários minutos.' }
    @{ Id = 'M2'; Script = 'Manutencao'; Texto = 'Verifica os arquivos de sistema (sfc /verifyonly).'; Perda = 'Nada; com reparo aprovado, roda sfc /scannow.' }
    @{ Id = 'M3'; Script = 'Manutencao'; Texto = 'Verifica o sistema de arquivos dos volumes fixos (Repair-Volume -Scan).'; Perda = 'Nada: só verifica.' }
    @{ Id = 'M4'; Script = 'Manutencao'; Texto = 'Garante o TRIM do NTFS ligado quando há SSD.'; Perda = 'Nada (padrão do Windows).' }
    @{ Id = 'M8'; Script = 'Manutencao'; Texto = 'Horário ativo do Windows Update por política.'; Perda = 'Reinicializações automáticas só fora do horário definido.' }
    @{ Id = 'A1'; Script = 'Aplicativos'; Texto = 'Remove apps de consumo da lista base (Clipchamp, Notícias, Clima, Solitaire, Xbox, jogos de fábrica etc.).'; Perda = 'Os apps removidos; reinstalação manual pela Microsoft Store.'; Aviso = 'Aprovar A1 aprova a lista base inteira.' }
    @{ Id = 'A2'; Script = 'Aplicativos'; Texto = 'Remove programas do fabricante escolhidos (Appx e MSI; EXE fica para remoção manual).'; Perda = 'Os programas removidos; reinstalação com o instalador do fabricante.'; Opcao = 'A2Remover' }
    @{ Id = 'A3'; Script = 'Aplicativos'; Texto = 'OneDrive não é removido (para tirá-lo da inicialização, use o I1).'; Perda = 'Nada: informativo.'; Informativo = $true }
    @{ Id = 'A4'; Script = 'Aplicativos'; Texto = 'Remove o Teams pessoal do Windows 11 (Chat). O Teams novo nunca é tocado.'; Perda = 'O Chat do Windows 11; reinstalação pela Microsoft Store.' }
    @{ Id = 'I1'; Script = 'Inicializacao'; Texto = 'Desabilita entradas de inicialização escolhidas (como o Gerenciador de Tarefas).'; Perda = 'Os programas escolhidos deixam de abrir sozinhos ao entrar.'; Opcao = 'I1Desabilitar' }
    @{ Id = 'I2'; Script = 'Inicializacao'; Texto = 'Edge sem aceleração de inicialização e sem execução em segundo plano.'; Perda = 'O Edge abre um pouco mais devagar na primeira vez.' }
    @{ Id = 'I3'; Script = 'Inicializacao'; Texto = 'Chrome sem execução em segundo plano.'; Perda = 'Notificações e apps do Chrome com ele fechado.' }
    @{ Id = 'I4'; Script = 'Inicializacao'; Texto = 'Nega execução em segundo plano aos apps da Store escolhidos.'; Perda = 'Notificações e atualização em segundo plano desses apps.'; Opcao = 'I4NegarSegundoPlano' }
    @{ Id = 'I5'; Script = 'Inicializacao'; Texto = 'Widgets desligados (Windows 11). Pulado com o driver UCPD ativo.'; Perda = 'O painel de Widgets.' }
    @{ Id = 'I6'; Script = 'Inicializacao'; Texto = 'Remove o app Microsoft Copilot de consumidor (não toca no Microsoft 365 Copilot).'; Perda = 'O app Copilot; reinstalação pela Microsoft Store.' }
    @{ Id = 'I7'; Script = 'Inicializacao'; Texto = 'Sugestões da web desligadas na caixa de busca (confiança baixa: conferir no cliente).'; Perda = 'Resultados da web na busca.' }
    @{ Id = 'I8'; Script = 'Inicializacao'; Texto = 'Gravação em segundo plano do Game Bar desligada.'; Perda = 'Gravar os últimos minutos de jogo.' }
    @{ Id = 'I9'; Script = 'Inicializacao'; Texto = 'Desabilita tarefas agendadas de terceiros escolhidas.'; Perda = 'O que a tarefa fazia (ex.: verificar atualização do programa).'; Opcao = 'I9Tarefas' }
    @{ Id = 'I10'; Script = 'Inicializacao'; Texto = 'Tipo de início de serviços de terceiros escolhidos (Manual ou Desativado).'; Perda = 'O que o serviço fazia com início automático; vale após reiniciar.'; Opcao = 'I10Servicos' }
    @{ Id = 'I11'; Script = 'Inicializacao'; Texto = 'Sugestões de terceiros desligadas (no Enterprise e Education, também experiências de consumidor).'; Perda = 'Sugestões e apps promovidos pelo Windows.' }
    @{ Id = 'I12'; Script = 'Inicializacao'; Texto = 'Recall sem snapshots e Click to Do desligado (só PCs Copilot+).'; Perda = 'Recall e Click to Do.' }
    @{ Id = 'V1'; Script = 'VisualEnergia'; Texto = 'Animações desligadas (mantém suavização de fontes, miniaturas e sombras).'; Perda = 'Animações de janelas, menus e barra de tarefas.' }
    @{ Id = 'V2'; Script = 'VisualEnergia'; Texto = 'Transparência desligada.'; Perda = 'Efeito de transparência.' }
    @{ Id = 'V3'; Script = 'VisualEnergia'; Texto = 'Plano de energia Desempenho máximo (alternativa em Modern Standby).'; Perda = 'Mais consumo e temperatura.'; Aviso = 'Em notebook reduz a autonomia da bateria.' }
    @{ Id = 'V4'; Script = 'VisualEnergia'; Texto = 'Modo de energia Melhor desempenho na tomada (só vale com o Equilibrado ativo).'; Perda = 'Mais consumo na tomada.' }
    @{ Id = 'V5'; Script = 'VisualEnergia'; Texto = 'Inicialização rápida: mantida; desliga só se escolhido.'; Perda = 'Desligada: boot a frio mais lento.' }
    @{ Id = 'V6'; Script = 'VisualEnergia'; Texto = 'Hibernação desligada, só em desktop (libera o hiberfil.sys).'; Perda = 'Hibernação e inicialização rápida.' }
    @{ Id = 'V7'; Script = 'VisualEnergia'; Texto = 'Num Lock ligado na inicialização.'; Perda = 'Nada.' }
    @{ Id = 'V8'; Script = 'VisualEnergia'; Texto = 'Mostrar extensões de arquivos conhecidos.'; Perda = 'Nada.' }
    @{ Id = 'V9'; Script = 'VisualEnergia'; Texto = 'Finalizar tarefa no menu da barra de tarefas (Windows 11 23H2 ou superior).'; Perda = 'Nada.' }
    @{ Id = 'V10'; Script = 'VisualEnergia'; Texto = 'Desliga o atalho das Teclas de Aderência (Shift 5 vezes).'; Perda = 'O atalho (o recurso continua em Configurações).' }
    @{ Id = 'L1'; Script = 'Limpeza'; Texto = 'Temporários do Windows (%windir%\Temp) antigos.'; Perda = 'Nada.' }
    @{ Id = 'L2'; Script = 'Limpeza'; Texto = 'Temporários de todos os perfis de usuário antigos.'; Perda = 'Nada.' }
    @{ Id = 'L3'; Script = 'Limpeza'; Texto = 'Cache do Chrome e do Edge (nunca cookies, senhas, histórico ou sessões).'; Perda = 'Primeiro acesso aos sites um pouco mais lento.' }
    @{ Id = 'L4'; Script = 'Limpeza'; Texto = 'Cache de download do Windows Update.'; Perda = 'Atualizações pendentes são baixadas de novo.'; Aviso = 'Exige aprovação específica do cliente.' }
    @{ Id = 'L5'; Script = 'Limpeza'; Texto = 'Lixeira de todos os usuários.'; Perda = 'O conteúdo da Lixeira, sem volta.'; Aviso = 'Exige aprovação específica do cliente.' }
    @{ Id = 'L6'; Script = 'Limpeza'; Texto = 'Windows.old (Limpeza de Disco).'; Perda = 'Voltar para a versão anterior do Windows.'; Aviso = 'Exige aprovação específica do cliente.' }
    @{ Id = 'L7'; Script = 'Limpeza'; Texto = 'Limpeza de componentes (DISM StartComponentCleanup, nunca ResetBase).'; Perda = 'Desinstalar atualizações já substituídas.'; Aviso = 'Exige aprovação específica do cliente.' }
    @{ Id = 'L8'; Script = 'Limpeza'; Texto = 'HDD: desfragmenta. SSD: garante a otimização agendada (TRIM).'; Perda = 'Nada.' }
    @{ Id = 'L9'; Script = 'Limpeza'; Texto = 'Sensor de Armazenamento ligado para temporários (Lixeira e Downloads nunca).'; Perda = 'Nada.' }
)

function Get-CatalogoPerfil {
    <# Itens do catálogo na ordem de execução dos scripts: Id, Script, Texto, Perda, Aviso, Opcao, Informativo. #>
    foreach ($i in $script:CatalogoPerfil) {
        [pscustomobject]@{
            Id = $i.Id; Script = $i.Script; Texto = $i.Texto; Perda = $i.Perda
            Aviso = $i['Aviso']; Opcao = $i['Opcao']; Informativo = [bool]$i['Informativo']
        }
    }
}

function ConvertFrom-Selecao {
    <# IDs ou números (1 = primeiro de Validos), separados por espaço ou vírgula, com faixas n-m. Devolve na ordem de Validos. #>
    [OutputType([string[]])]
    param([AllowEmptyString()][string]$Texto, [Parameter(Mandatory)][string[]]$Validos)
    $escolhidos = New-Object System.Collections.Generic.HashSet[string]
    foreach ($t in @($Texto -split '[\s,;]+' | Where-Object { $_ })) {
        $faixa = [regex]::Match($t, '^(\d+)-(\d+)$')
        $indices = $null
        if ($faixa.Success) { $indices = [int]$faixa.Groups[1].Value..[int]$faixa.Groups[2].Value }
        elseif ($t -match '^\d+$') { $indices = @([int]$t) }
        if ($null -ne $indices) {
            foreach ($n in $indices) {
                if ($n -lt 1 -or $n -gt $Validos.Count) { throw [ArgumentException]"Opção '$t' fora da lista (1 a $($Validos.Count))." }
                [void]$escolhidos.Add($Validos[$n - 1])
            }
            continue
        }
        $id = @($Validos | Where-Object { $_ -eq $t })
        if (-not $id.Count) { throw [ArgumentException]"Opção '$t' não existe na lista." }
        [void]$escolhidos.Add($id[0])
    }
    $Validos | Where-Object { $escolhidos.Contains($_) }
}

function ConvertTo-LiteralPerfil {
    <# Valor em sintaxe de arquivo de dados .psd1: string com aspas simples escapadas, número, booleano, lista ou tabela. #>
    param($Valor, [string]$Recuo = '')
    if ($null -eq $Valor) { return '$null' }
    if ($Valor -is [bool]) { return $(if ($Valor) { '$true' } else { '$false' }) }
    if ($Valor -is [int] -or $Valor -is [long]) { return [string]$Valor }
    if ($Valor -is [string]) { return "'" + $Valor.Replace("'", "''") + "'" }
    if ($Valor -is [Collections.IDictionary]) {
        if (-not $Valor.Count) { return '@{}' }
        $interno = "$Recuo    "
        $linhas = foreach ($k in @($Valor.Keys | Sort-Object)) { '{0}{1} = {2}' -f $interno, (ConvertTo-LiteralPerfil ([string]$k)), (ConvertTo-LiteralPerfil $Valor[$k] $interno) }
        return "@{`r`n" + ($linhas -join "`r`n") + "`r`n$Recuo}"
    }
    if ($Valor -is [Collections.IEnumerable]) { return '@(' + ((@($Valor) | ForEach-Object { ConvertTo-LiteralPerfil $_ $Recuo }) -join ', ') + ')' }
    throw "Tipo não suportado no perfil: $($Valor.GetType().FullName)"
}

function ConvertTo-TextoPerfil {
    <# Texto do .psd1 no formato de perfis\exemplo.psd1. Dados: Cliente, UsuarioSid, Aplicar, Opcoes. #>
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Dados)
    $opcoes = if ($Dados.Opcoes) { $Dados.Opcoes } else { @{} }
    $protegidos = [ordered]@{ Aplicativos = @(); Inicializacao = @(); Servicos = @(); Tarefas = @() }
    @(
        "# Perfil de cliente gerado pelo Menu (Novo perfil) em $((Get-Date).ToString('yyyy-MM-dd HH:mm')). Apenas dados."
        '@{'
        "    Cliente    = $(ConvertTo-LiteralPerfil ([string]$Dados.Cliente))"
        "    UsuarioSid = $(ConvertTo-LiteralPerfil ([string]$Dados.UsuarioSid))"
        "    Aplicar    = @($((@($Dados.Aplicar) | ForEach-Object { ConvertTo-LiteralPerfil ([string]$_) }) -join ', '))"
        '    Pular      = @()'
        "    Protegidos = $(ConvertTo-LiteralPerfil $protegidos '    ')"
        "    Opcoes     = $(ConvertTo-LiteralPerfil $opcoes '    ')"
        '}'
        ''
    ) -join "`r`n"
}

function Save-PerfilGerado {
    <# Grava <Pasta>\<Cliente>.psd1 em UTF-8 com BOM e relê com Import-PerfilCliente; não sobrescreve sem -Force. #>
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Dados, [Parameter(Mandatory)][string]$Pasta, [switch]$Force)
    if ([string]$Dados.Cliente -notmatch '^[\w.-]{1,60}$') { throw 'Cliente aceita apenas letras, números, ponto, hífen e sublinhado (até 60).' }
    $arquivo = Join-Path $Pasta "$($Dados.Cliente).psd1"
    if ((Test-Path -LiteralPath $arquivo) -and -not $Force) { throw "Já existe um perfil para $($Dados.Cliente): $arquivo" }
    if (-not (Test-Path -LiteralPath $Pasta)) { New-Item -ItemType Directory -Path $Pasta -Force | Out-Null }
    [IO.File]::WriteAllText($arquivo, (ConvertTo-TextoPerfil -Dados $Dados), (New-Object Text.UTF8Encoding $true))
    try { Import-PerfilCliente -Caminho $arquivo | Out-Null }
    catch { Remove-Item -LiteralPath $arquivo -Force -ErrorAction SilentlyContinue; throw }
    $arquivo
}

#endregion

#region Listas da máquina (I1, I4, I9, I10, A2)

# As funções de leitura e filtro vêm dos próprios scripts, para a lista mostrar só o que o script aceita na aplicação.
# Cada script é carregado num módulo dinâmico (as funções auxiliares dele não vazam e Get-Opcao, presente nos dois, não colide).
foreach ($c in @(
        @{ Nome = 'Otimizacao.Leitura.Inicializacao'; Arquivo = 'Inicializacao.ps1'; Funcoes = 'Get-FonteInicializacao', 'Test-ComponenteWindows', 'Get-InicioServico', 'Get-ExecutavelComando' }
        @{ Nome = 'Otimizacao.Leitura.Aplicativos'; Arquivo = 'Aplicativos.ps1'; Funcoes = 'Get-ProgramaMaquina', 'Get-MotivoProibido' }
    )) {
    New-Module -Name $c.Nome -ArgumentList (Join-Path $PSScriptRoot $c.Arquivo), $c.Funcoes -ScriptBlock {
        param($Arquivo, $Funcoes)
        . $Arquivo -Perfil 'nao-usado.psd1'
        Export-ModuleMember -Function $Funcoes
    } | Import-Module -Force
}
# Os scripts reimportam o módulo comum com -Force, o que o retira desta sessão: importar de novo, sem -Force.
Import-Module (Join-Path $PSScriptRoot 'Otimizacao.Comum.psm1')

function Get-CandidatoI1 {
    <# Entradas de inicialização da máquina e do usuário alvo que o I1 aceita (sem componentes do Windows). #>
    param([Parameter(Mandatory)]$Alvo)
    $entradas = @(Get-FonteInicializacao -Raiz 'Registry::HKEY_LOCAL_MACHINE' -Escopo Maquina)
    $entradas += @(Invoke-NoHiveUsuario -Sid $Alvo.Sid -Perfil $Alvo.Perfil -ScriptBlock {
            param($raiz)
            Get-FonteInicializacao -Raiz $raiz -Escopo Usuario -PerfilUsuario $Alvo.Perfil
        })
    $entradas | Where-Object { -not (Test-ComponenteWindows $_.Comando) } | Sort-Object -Property Nome -Unique |
        ForEach-Object { [pscustomobject]@{ Nome = $_.Nome; Origem = $_.Origem; Comando = $_.Comando } }
}

function Get-CandidatoI4 {
    <# Apps da Store do usuário alvo com Package Family Name no formato que o I4 aceita. #>
    param([Parameter(Mandatory)]$Alvo)
    Get-AppxPackage -User $Alvo.Sid -ErrorAction Stop |
        Where-Object { -not $_.IsFramework -and -not $_.IsResourcePackage -and -not $_.NonRemovable -and [string]$_.SignatureKind -ne 'System' -and
            $_.PackageFamilyName -match '^[A-Za-z0-9.\-]+_[a-z0-9]{13}$' } |
        Sort-Object -Property PackageFamilyName -Unique |
        ForEach-Object { [pscustomobject]@{ Nome = (Get-NomeExibicaoAppx -Pacote $_).Nome; Pfn = $_.PackageFamilyName } } |
        Sort-Object -Property Nome
}

function Get-EmpresaExecutavel {
    <# Empresa nas propriedades de versão do executável, ou $null. #>
    param([string]$Caminho)
    if (-not $Caminho -or -not (Test-Path -LiteralPath $Caminho -PathType Leaf)) { return $null }
    (Get-Item -LiteralPath $Caminho).VersionInfo.CompanyName
}

function Test-ProgramaMicrosoft {
    <#
        Verdadeiro para programa do Windows (%windir%) ou da Microsoft fora dele (Defender em ProgramData, Edge Update).
        Mais restrito que o I9 e o I10, que só recusam %windir% e \Microsoft\: o Defender é intocável (CLAUDE.md).
    #>
    param([string]$Comando)
    if (Test-ComponenteWindows $Comando) { return $true }
    [string](Get-EmpresaExecutavel (Get-ExecutavelComando $Comando)) -like 'Microsoft*'
}

function Get-CandidatoI9 {
    <#
        Tarefas agendadas fora de \Microsoft\, não desabilitadas, que executam um programa (handler COM, típico do Windows,
        fica de fora) e nenhum programa do Windows ou da Microsoft.
    #>
    Get-ScheduledTask | Where-Object { $_.TaskPath -notlike '\Microsoft\*' -and [string]$_.State -ne 'Disabled' } |
        Where-Object {
            $exes = @(@($_.Actions) | Where-Object { $_ -and $_.PSObject.Properties['Execute'] -and $_.Execute } | ForEach-Object { $_.Execute })
            $exes.Count -and -not @($exes | Where-Object { Test-ProgramaMicrosoft $_ }).Count
        } |
        ForEach-Object { [pscustomobject]@{ Caminho = $_.TaskPath + $_.TaskName; Estado = [string]$_.State } } |
        Sort-Object -Property Caminho
}

function Get-CandidatoI10 {
    <# Serviços Win32 de terceiros (nem do Windows nem da Microsoft) com início automático ou manual, como o I10 exige. #>
    $inicio = @{ 2 = 'Automático'; 3 = 'Manual' }
    foreach ($s in @(Get-Service -ErrorAction SilentlyContinue | Sort-Object -Property Name)) {
        $i = Get-InicioServico $s.Name
        if (-not $i -or -not ($i.Tipo -band 0x30) -or -not $inicio.ContainsKey($i.Start) -or (Test-ProgramaMicrosoft $i.ImagePath)) { continue }
        [pscustomobject]@{ Nome = $s.Name; Exibicao = $s.DisplayName; Inicio = $inicio[$i.Start] }
    }
}

function Get-CandidatoA2 {
    <# Programas da máquina que o A2 aceita remover (sem Microsoft, sem ferramentas de driver e BIOS, sem os nunca removidos). #>
    Get-ProgramaMaquina | Where-Object { -not (Get-MotivoProibido -Programa $_ -A2) } | Sort-Object -Property Nome |
        ForEach-Object { [pscustomobject]@{ Nome = $_.Nome; Fabricante = $_.Fabricante; Versao = $_.Versao; Tipo = $_.Tipo; Id = $_.Id } }
}

#endregion
