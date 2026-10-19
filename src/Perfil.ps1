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
# Manutencao: Quando (quando usar), Corrige (o que corrige) e Fonte, mostrados no Novo perfil.
$script:CatalogoPerfil = @(
    @{ Id = 'M1'; Script = 'Manutencao'; Texto = 'Verifica a imagem do Windows (DISM ScanHealth).'; Perda = 'Disco e CPU ocupados por vários minutos; com reparo aprovado, consome banda de internet (Windows Update).'
        Quando = 'Antes do M2, sempre que houver sinais de arquivos de sistema danificados, e quando o sfc não conseguir reparar.'
        Corrige = 'Diz se a imagem do Windows está íntegra, reparável ou não reparável. Com reparo aprovado (RestoreHealth), corrige a imagem, que é a fonte dos arquivos usados pelo sfc, baixando do Windows Update.'
        Fonte = 'support.microsoft.com KB929833 (rodar o DISM antes do sfc); learn.microsoft.com: Repair a Windows Image' }
    @{ Id = 'M2'; Script = 'Manutencao'; Texto = 'Verifica os arquivos de sistema (sfc /verifyonly).'; Perda = 'Disco e CPU ocupados por vários minutos.'
        Quando = 'Recursos do Windows que não funcionam direito, erros do sistema, Windows travando ou parando de responder.'
        Corrige = 'Arquivos de sistema protegidos corrompidos: com reparo aprovado (sfc /scannow), troca pela cópia guardada. Sem reparo aprovado, só verifica.'
        Fonte = 'support.microsoft.com KB929833 (System File Checker)' }
    @{ Id = 'M3'; Script = 'Manutencao'; Texto = 'Verifica o sistema de arquivos dos volumes fixos (Repair-Volume -Scan).'; Perda = 'Disco e CPU ocupados por vários minutos.'
        Quando = 'Erros de disco ou NTFS na Coleta (M6), ou para conferir o sistema de arquivos sem tirar o disco de uso.'
        Corrige = 'Nada: só verifica e registra os erros (como chkdsk /scan). Havendo erro, o fluxo para e a correção (chkdsk /spotfix ou /f, com reinicialização) fica manual.'
        Fonte = 'learn.microsoft.com: Repair-Volume' }
    @{ Id = 'M4'; Script = 'Manutencao'; Texto = 'Garante o TRIM do NTFS ligado quando há SSD.'; Perda = 'Nada (padrão do Windows).'
        Quando = 'SSD com o TRIM desligado na Coleta (DisableDeleteNotify = 1). Não usar se ele foi desligado de propósito: alguns dispositivos perdem desempenho com o TRIM.'
        Corrige = 'Liga o aviso ao SSD dos blocos liberados ao apagar arquivos (TRIM). Em HDD não tem efeito.'
        Fonte = 'learn.microsoft.com: fsutil behavior (disabledeletenotify)' }
    @{ Id = 'M8'; Script = 'Manutencao'; Texto = 'Horário ativo do Windows Update por política.'; Perda = 'O usuário não muda mais o horário ativo em Configurações ("gerenciado pela organização") e o ajuste automático do horário ativo é desligado.'
        Quando = 'O Windows Update reinicia o computador durante o expediente.'
        Corrige = 'As reinicializações automáticas depois de atualizações passam a acontecer só fora do horário ativo (até 18 h).'
        Fonte = 'learn.microsoft.com: Manage device restarts after updates' }
    @{ Id = 'A1'; Script = 'Aplicativos'; Texto = 'Remove apps de consumo da lista base (Clipchamp, Notícias, Clima, Solitaire, Xbox, jogos de fábrica etc.).'; Perda = 'Os apps removidos, a gravação de tela Win+G (Game Bar) e o app Xbox; reinstalação manual pela Microsoft Store.'; Aviso = 'Aprovar A1 aprova a lista base inteira.' }
    @{ Id = 'A2'; Script = 'Aplicativos'; Texto = 'Remove programas do fabricante escolhidos (Appx e MSI; EXE fica para remoção manual).'; Perda = 'Os programas removidos; reinstalação manual pela Microsoft Store (Appx) ou pelo instalador do fabricante (MSI).'; Opcao = 'A2Remover' }
    @{ Id = 'A3'; Script = 'Aplicativos'; Texto = 'OneDrive não é removido (para tirá-lo da inicialização, use o I1).'; Perda = 'Nada: informativo.'; Informativo = $true }
    @{ Id = 'A4'; Script = 'Aplicativos'; Texto = 'Remove o Teams pessoal do Windows 11 (Chat). O Teams novo nunca é tocado.'; Perda = 'O Chat do Windows 11; reinstalação pela Microsoft Store.' }
    @{ Id = 'I1'; Script = 'Inicializacao'; Texto = 'Desabilita entradas de inicialização escolhidas (como o Gerenciador de Tarefas).'; Perda = 'O programa não inicia sozinho.'; Opcao = 'I1Desabilitar' }
    @{ Id = 'I2'; Script = 'Inicializacao'; Texto = 'Edge sem aceleração de inicialização e sem execução em segundo plano.'; Perda = 'O Edge fica cerca de 1 s mais lento para abrir.' }
    @{ Id = 'I3'; Script = 'Inicializacao'; Texto = 'Chrome sem execução em segundo plano.'; Perda = 'Notificações com o app fechado.' }
    @{ Id = 'I4'; Script = 'Inicializacao'; Texto = 'Nega execução em segundo plano aos apps da Store escolhidos.'; Perda = 'Notificações com o app fechado.'; Opcao = 'I4NegarSegundoPlano' }
    @{ Id = 'I5'; Script = 'Inicializacao'; Texto = 'Widgets desligados (Windows 11). Pulado com o driver UCPD ativo.'; Perda = 'O painel de widgets.' }
    @{ Id = 'I6'; Script = 'Inicializacao'; Texto = 'Remove o app Microsoft Copilot de consumidor (não toca no Microsoft 365 Copilot).'; Perda = 'O app Copilot; volta só reinstalando pela Microsoft Store.' }
    @{ Id = 'I7'; Script = 'Inicializacao'; Texto = 'Sugestões da web desligadas na caixa de busca (confiança baixa: conferir no cliente).'; Perda = 'Resultados da web no Iniciar (se tiver efeito).' }
    @{ Id = 'I8'; Script = 'Inicializacao'; Texto = 'Gravação em segundo plano do Game Bar desligada.'; Perda = 'A gravação do Game Bar.' }
    @{ Id = 'I9'; Script = 'Inicializacao'; Texto = 'Desabilita tarefas agendadas de terceiros escolhidas.'; Perda = 'A tarefa não inicia sozinha.'; Opcao = 'I9Tarefas' }
    @{ Id = 'I10'; Script = 'Inicializacao'; Texto = 'Tipo de início de serviços de terceiros escolhidos (Manual ou Desativado).'; Perda = 'O serviço não inicia sozinho (vale após reiniciar).'; Opcao = 'I10Servicos' }
    @{ Id = 'I11'; Script = 'Inicializacao'; Texto = 'Sugestões de terceiros desligadas (no Enterprise e Education, também experiências de consumidor).'; Perda = 'Sugestões e dicas.' }
    @{ Id = 'I12'; Script = 'Inicializacao'; Texto = 'Recall sem snapshots e Click to Do desligado (só PCs Copilot+).'; Perda = 'Recall e Click to Do.' }
    @{ Id = 'V1'; Script = 'VisualEnergia'; Texto = 'Animações desligadas (mantém suavização de fontes, miniaturas e sombras).'; Perda = 'Animações.' }
    @{ Id = 'V2'; Script = 'VisualEnergia'; Texto = 'Transparência desligada.'; Perda = 'Transparência.' }
    @{ Id = 'V3'; Script = 'VisualEnergia'; Texto = 'Plano de energia Desempenho máximo (alternativa em Modern Standby).'; Perda = 'Mais consumo de energia e temperatura.'; Aviso = 'Em notebook reduz a autonomia da bateria.' }
    @{ Id = 'V4'; Script = 'VisualEnergia'; Texto = 'Modo de energia Melhor desempenho na tomada (só vale com o Equilibrado ativo).'; Perda = 'Não declarado no script; mesma natureza do V3 (mais consumo na tomada).' }
    @{ Id = 'V5'; Script = 'VisualEnergia'; Texto = 'Inicialização rápida: mantida; desliga só se escolhido.'; Perda = 'Desligada: boot a frio mais lento.' }
    @{ Id = 'V6'; Script = 'VisualEnergia'; Texto = 'Hibernação desligada, só em desktop (libera o hiberfil.sys).'; Perda = 'Hibernação e inicialização rápida (boot a frio mais lento).' }
    @{ Id = 'V7'; Script = 'VisualEnergia'; Texto = 'Num Lock ligado na inicialização.'; Perda = 'Nada.' }
    @{ Id = 'V8'; Script = 'VisualEnergia'; Texto = 'Mostrar extensões de arquivos conhecidos.'; Perda = 'Nada.' }
    @{ Id = 'V9'; Script = 'VisualEnergia'; Texto = 'Finalizar tarefa no menu da barra de tarefas (Windows 11 23H2 ou superior).'; Perda = 'Nada.' }
    @{ Id = 'V10'; Script = 'VisualEnergia'; Texto = 'Desliga o atalho das Teclas de Aderência (Shift 5 vezes).'; Perda = 'O atalho de acessibilidade (o recurso continua disponível em Configurações).' }
    @{ Id = 'L1'; Script = 'Limpeza'; Texto = 'Temporários do Windows (%windir%\Temp) antigos.'; Perda = 'Arquivos temporários apagados, sem reversão.' }
    @{ Id = 'L2'; Script = 'Limpeza'; Texto = 'Temporários de todos os perfis de usuário antigos.'; Perda = 'Arquivos temporários apagados, sem reversão.' }
    @{ Id = 'L3'; Script = 'Limpeza'; Texto = 'Cache do Chrome e do Edge (nunca cookies, senhas, histórico ou sessões).'; Perda = 'Caches apagados, sem reversão; primeiras páginas mais lentas até o cache se refazer.' }
    @{ Id = 'L4'; Script = 'Limpeza'; Texto = 'Cache de download do Windows Update.'; Perda = 'Arquivos apagados, sem reversão; o Windows Update baixa de novo o que estiver pendente.'; Aviso = 'Exige aprovação específica do cliente.' }
    @{ Id = 'L5'; Script = 'Limpeza'; Texto = 'Lixeira de todos os usuários.'; Perda = 'O conteúdo da Lixeira, sem reversão.'; Aviso = 'Exige aprovação específica do cliente.' }
    @{ Id = 'L6'; Script = 'Limpeza'; Texto = 'Windows.old (Limpeza de Disco).'; Perda = 'A opção de voltar à versão anterior do Windows.'; Aviso = 'Exige aprovação específica do cliente.' }
    @{ Id = 'L7'; Script = 'Limpeza'; Texto = 'Limpeza de componentes (DISM StartComponentCleanup, nunca ResetBase).'; Perda = 'Desinstalar atualizações já substituídas.'; Aviso = 'Exige aprovação específica do cliente.' }
    @{ Id = 'L8'; Script = 'Limpeza'; Texto = 'HDD: desfragmenta. SSD: garante a otimização agendada (TRIM).'; Perda = 'Nada.' }
    @{ Id = 'L9'; Script = 'Limpeza'; Texto = 'Sensor de Armazenamento ligado para temporários (Lixeira e Downloads nunca).'; Perda = 'Nada.' }
)

function Get-CatalogoPerfil {
    <# Itens do catálogo na ordem de execução dos scripts: Id, Script, Texto, Perda, Aviso, Opcao, Informativo, Quando, Corrige, Fonte. #>
    foreach ($i in $script:CatalogoPerfil) {
        [pscustomobject]@{
            Id = $i.Id; Script = $i.Script; Texto = $i.Texto; Perda = $i.Perda
            Aviso = $i['Aviso']; Opcao = $i['Opcao']; Informativo = [bool]$i['Informativo']
            Quando = $i['Quando']; Corrige = $i['Corrige']; Fonte = $i['Fonte']
        }
    }
}

function Test-PreSelecionado {
    <# Item marcado ao abrir o Novo perfil: todos, menos a Manutencao, o informativo A3, o I3 e o I9. #>
    param([Parameter(Mandatory)]$Item)
    $Item.Script -ne 'Manutencao' -and -not $Item.Informativo -and $Item.Id -notin 'I3', 'I9'
}

function Test-NomeCliente {
    param([AllowEmptyString()][string]$Nome)
    $Nome -match '^[\w.-]{1,60}$'
}

function Test-HorarioM8 {
    <# Horas de 0 a 23 e intervalo de 1 a 18 h, mesma regra do Manutencao. #>
    param([int]$Inicio, [int]$Fim)
    $duracao = ($Fim - $Inicio + 24) % 24
    $Inicio -ge 0 -and $Inicio -le 23 -and $Fim -ge 0 -and $Fim -le 23 -and $duracao -ge 1 -and $duracao -le 18
}

function New-DadosPerfil {
    <#
        Dados do perfil a partir das escolhas da janela: itens marcados (na ordem do catálogo, sem o informativo),
        escolhas das listas (Id -> valores; no I10, tabela serviço = Manual|Disabled) e opções dos itens marcados.
        Item de lista sem escolha sai de Aplicar. Devolve Dados (para Save-PerfilGerado) e Desmarcados.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Só monta os dados em memória; quem grava é o Save-PerfilGerado.')]
    param(
        [Parameter(Mandatory)][string]$Cliente,
        [AllowEmptyString()][string]$UsuarioSid = '',
        [string[]]$Marcados = @(),
        [hashtable]$Escolhas = @{},
        [hashtable]$Opcoes = @{}
    )
    $aplicar = New-Object System.Collections.Generic.List[string]
    $desmarcados = New-Object System.Collections.Generic.List[string]
    $op = @{}
    foreach ($it in Get-CatalogoPerfil) {
        if ($Marcados -notcontains $it.Id -or $it.Informativo) { continue }
        if ($it.Opcao) {
            $e = $Escolhas[$it.Id]
            $n = if ($e -is [Collections.IDictionary]) { $e.Count } else { @($e | Where-Object { $_ }).Count }
            if (-not $n) { $desmarcados.Add($it.Id); continue }
            $op[$it.Opcao] = if ($e -is [Collections.IDictionary]) { $e } else { @($e | Where-Object { $_ }) }
        }
        $aplicar.Add($it.Id)
    }
    $doItem = @{ M1Reparar = 'M1'; M2Reparar = 'M2'; M8Inicio = 'M8'; M8Fim = 'M8'; V5DesligarInicializacaoRapida = 'V5' }
    foreach ($k in @($Opcoes.Keys)) { if ($doItem.ContainsKey($k) -and $aplicar.Contains($doItem[$k])) { $op[$k] = $Opcoes[$k] } }
    [pscustomobject]@{
        Dados       = @{ Cliente = $Cliente; UsuarioSid = $UsuarioSid; Aplicar = $aplicar.ToArray(); Opcoes = $op }
        Desmarcados = $desmarcados.ToArray()
    }
}

function Get-ResumoPerfil {
    <# Linhas do resumo antes de gravar: cliente, usuário, itens por script com o escolhido nas listas (Rotulos: Id -> textos) e opções. #>
    [OutputType([string[]])]
    param([Parameter(Mandatory)][hashtable]$Dados, [Parameter(Mandatory)][string]$Usuario, [hashtable]$Rotulos = @{}, [string[]]$Desmarcados = @())
    $l = New-Object System.Collections.Generic.List[string]
    $l.Add("Cliente:  $($Dados.Cliente)")
    $l.Add("Usuário:  $Usuario")
    $catalogo = @(Get-CatalogoPerfil)
    foreach ($s in @($catalogo | ForEach-Object { $_.Script } | Select-Object -Unique)) {
        $itens = @($catalogo | Where-Object { $_.Script -eq $s -and $Dados.Aplicar -contains $_.Id })
        if (-not $itens.Count) { continue }
        $l.Add('')
        $l.Add($s)
        foreach ($it in $itens) {
            $l.Add(('  {0,-4} {1}' -f $it.Id, $it.Texto))
            foreach ($r in @($Rotulos[$it.Id])) { if ($r) { $l.Add("         -> $r") } }
        }
    }
    $opcoes = @('M1Reparar', 'M2Reparar', 'M8Inicio', 'M8Fim', 'V5DesligarInicializacaoRapida') | Where-Object { $Dados.Opcoes.ContainsKey($_) }
    if (@($opcoes).Count) { $l.Add(''); foreach ($k in $opcoes) { $l.Add("  $k = $($Dados.Opcoes[$k])") } }
    if ($Desmarcados.Count) { $l.Add(''); $l.Add("Desmarcados por nada escolhido na lista: $($Desmarcados -join ', ').") }
    $l.ToArray()
}

function ConvertTo-LiteralPerfil {
    <# Valor em sintaxe de arquivo de dados .psd1: string com aspas simples escapadas, número, booleano, lista ou tabela. #>
    param($Valor, [string]$Recuo = '')
    if ($null -eq $Valor) { return '$null' }
    if ($Valor -is [bool]) { return $(if ($Valor) { '$true' } else { '$false' }) }
    if ($Valor -is [int] -or $Valor -is [long]) { return [string]$Valor }
    # Escape oficial do PowerShell: dobra também os apóstrofos tipográficos (U+2018 a U+201B), que ele trata como aspas.
    if ($Valor -is [string]) { return "'" + [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($Valor) + "'" }
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

function Get-UsuarioLocal {
    <# Perfis de usuário locais não especiais: Sid, Nome (DOMINIO\usuario, ou o SID se não resolver) e Perfil. #>
    Get-CimInstance -ClassName Win32_UserProfile -Filter 'Special = False' | ForEach-Object {
        $nome = try { ([Security.Principal.SecurityIdentifier]$_.SID).Translate([Security.Principal.NTAccount]).Value } catch { $_.SID }
        [pscustomobject]@{ Sid = $_.SID; Nome = $nome; Perfil = $_.LocalPath }
    } | Sort-Object -Property Nome
}

function Get-CandidatoA2 {
    <#
        Programas da máquina que o A2 aceita remover: sem Microsoft, sem ferramentas de driver e BIOS, sem os nunca
        removidos, sem Appx NonRemovable ou do sistema (o Remove-PacoteAppx recusa) e sem programa de fabricante vazio
        com nome ou Id da Microsoft (componentes do Windows sem fabricante no registro).
    #>
    $sistema = @(try { Get-AppxPackage -AllUsers -ErrorAction Stop | Where-Object { $_.NonRemovable -or [string]$_.SignatureKind -eq 'System' } | ForEach-Object { $_.Name } }
        catch { Write-Warning "A2: não foi possível ler os pacotes Appx de todos os usuários ($($_.Exception.Message))." })
    Get-ProgramaMaquina | Where-Object {
        -not (Get-MotivoProibido -Programa $_ -A2) -and -not ($_.Tipo -eq 'Appx' -and $sistema -contains $_.Id) -and
        -not (-not $_.Fabricante -and ($_.Nome -like 'Microsoft*' -or $_.Id -like 'Microsoft*'))
    } | Sort-Object -Property Nome |
        ForEach-Object { [pscustomobject]@{ Nome = $_.Nome; Fabricante = $_.Fabricante; Versao = $_.Versao; Tipo = $_.Tipo; Id = $_.Id } }
}

#endregion

#region Novo perfil (janela)

function Get-ListaItem {
    <# Lista lida da máquina para um item de lista: Valor (gravado no perfil) e Rotulo (mostrado). #>
    param([Parameter(Mandatory)][string]$Id, $Alvo)
    switch ($Id) {
        'I1' { Get-CandidatoI1 -Alvo $Alvo | ForEach-Object { [pscustomobject]@{ Valor = $_.Nome; Rotulo = "$($_.Nome)  [$($_.Origem)]  $($_.Comando)" } } }
        'I4' { Get-CandidatoI4 -Alvo $Alvo | ForEach-Object { [pscustomobject]@{ Valor = $_.Pfn; Rotulo = "$($_.Nome)  [$($_.Pfn)]" } } }
        'I9' { Get-CandidatoI9 | ForEach-Object { [pscustomobject]@{ Valor = $_.Caminho; Rotulo = "$($_.Caminho)  [$($_.Estado)]" } } }
        'I10' { Get-CandidatoI10 | ForEach-Object { [pscustomobject]@{ Valor = $_.Nome; Rotulo = "$($_.Exibicao) ($($_.Nome))  [$($_.Inicio)]" } } }
        'A2' { Get-CandidatoA2 | ForEach-Object { [pscustomobject]@{ Valor = $_.Id; Rotulo = "$($_.Nome) $($_.Versao)  [$($_.Fabricante), $($_.Tipo)]" } } }
    }
}

function Show-JanelaNovoPerfil {
    <#
        Assistente do Novo perfil em 5 passos: cliente e usuário alvo; itens por script (pré-selecionados conforme
        Test-PreSelecionado, com o detalhe do item e, na Manutencao, quando usar e o que corrige); listas lidas da
        máquina; opções dos itens marcados; resumo e gravação. Usa os auxiliares de janela do Menu (carregado por ele).
        Devolve o caminho gravado, ou $null se cancelado.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Grava só no último passo, com o botão Gravar perfil.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Pasta', Justification = 'Lido nos manipuladores de evento da janela.')]
    param([Parameter(Mandatory)][string]$Pasta)
    $cor = $script:CorJanela
    $fonte = $script:FonteJanela
    $catalogo = @(Get-CatalogoPerfil)
    $w = @{ Passo = 0; Sobrescrever = $false; Marcados = @(); Abas = @{}; SidListas = $null; Alvo = $null; Valores = @{}; Opcoes = @{}; Resultado = $null; Arquivo = $null }

    $f = New-Object Windows.Forms.Form
    $f.Text = 'Novo perfil'; Set-TamanhoJanela -Janela $f -Largura 1100 -Altura 760 -MinLargura 900 -MinAltura 600
    $f.StartPosition = 'CenterParent'; $f.Font = $fonte.Normal; $f.BackColor = $cor.Fundo; $f.MinimizeBox = $false; $f.ShowInTaskbar = $false

    $passos = 'Cliente e usuário', 'Itens por script', 'Listas da máquina', 'Opções', 'Resumo'
    $lado = New-Object Windows.Forms.Panel; $lado.Dock = 'Left'; $lado.Width = 220; $lado.BackColor = $cor.Branco
    $rotPassos = @(for ($i = 0; $i -lt $passos.Count; $i++) {
            $l = New-RotuloJanela -Texto ''; $l.Location = [Drawing.Point]::new(20, 24 + 40 * $i); $lado.Controls.Add($l); $l
        })

    $rodape = New-Object Windows.Forms.FlowLayoutPanel; $rodape.Dock = 'Bottom'; $rodape.Height = 62; $rodape.FlowDirection = 'RightToLeft'
    $rodape.Padding = New-Object Windows.Forms.Padding(20, 12, 12, 12); $rodape.BackColor = $cor.Branco
    $bAvancar = New-BotaoJanela -Texto 'Avançar' -Principal -Largura 140
    $bVoltar = New-BotaoJanela -Texto 'Voltar' -Largura 110
    $bCancelar = New-BotaoJanela -Texto 'Cancelar' -Largura 110
    $rodape.Controls.AddRange(@($bAvancar, $bVoltar, $bCancelar))

    $conteudo = New-Object Windows.Forms.Panel; $conteudo.Dock = 'Fill'; $conteudo.Padding = New-Object Windows.Forms.Padding(24, 16, 24, 8)
    $paginas = @(for ($i = 0; $i -lt $passos.Count; $i++) { $p = New-Object Windows.Forms.Panel; $p.Dock = 'Fill'; $p.Visible = $false; $conteudo.Controls.Add($p); $p })

    # Passo 1: cliente e usuário alvo.
    $p1 = New-PilhaJanela
    $p1.Controls.Add((New-RotuloJanela -Texto 'Cliente e usuário' -Fonte $fonte.Sub))
    $p1.Controls.Add((New-RotuloJanela -Texto 'Nome do cliente' -Fonte $fonte.Negrito))
    $txtCliente = New-Object Windows.Forms.TextBox; $txtCliente.Name = 'Cliente'; $txtCliente.Width = 380
    $p1.Controls.Add($txtCliente)
    $p1.Controls.Add((New-RotuloJanela -Texto 'Letras, números, ponto, hífen e sublinhado (até 60).' -Cor $cor.Texto2))
    $rotErro1 = New-RotuloJanela -Texto '' -Cor $cor.Falha; $p1.Controls.Add($rotErro1)
    $sep = New-RotuloJanela -Texto 'Usuário alvo (as configurações de usuário são gravadas no perfil dele)' -Fonte $fonte.Negrito
    $sep.Margin = New-Object Windows.Forms.Padding(0, 16, 0, 4); $p1.Controls.Add($sep)
    $usuarios = @([pscustomobject]@{ Sid = ''; Nome = 'Usuário conectado no momento do fluxo' }) + @(Get-UsuarioLocal)
    $radios = @(foreach ($u in $usuarios) {
            $r = New-Object Windows.Forms.RadioButton; $r.Text = $u.Nome; $r.Tag = $u; $r.AutoSize = $true; $r.Margin = New-Object Windows.Forms.Padding(0, 4, 0, 4)
            $p1.Controls.Add($r); $r
        })
    $radios[0].Checked = $true
    $paginas[0].Controls.Add($p1)

    # Passo 2: catálogo com caixas de marcar e o detalhe do item selecionado.
    $topo2 = New-PilhaJanela; $topo2.Dock = 'Top'; $topo2.Height = 76; $topo2.AutoScroll = $false
    $topo2.Controls.Add((New-RotuloJanela -Texto 'Itens por script' -Fonte $fonte.Sub))
    $rotConta = New-RotuloJanela -Texto '' -Cor $cor.Texto2; $topo2.Controls.Add($rotConta)
    $cat = New-Object Windows.Forms.ListView
    $cat.Name = 'Catalogo'; $cat.View = 'Details'; $cat.CheckBoxes = $true; $cat.FullRowSelect = $true; $cat.Dock = 'Fill'; $cat.ShowItemToolTips = $true
    $cat.BorderStyle = 'FixedSingle'; $cat.HeaderStyle = 'Nonclickable'; $cat.HideSelection = $false
    foreach ($c in @(@('Item', 70), @('Ajuste', 400), @('O que se perde', 330))) { [void]$cat.Columns.Add($c[0], $c[1]) }
    foreach ($s in @($catalogo | ForEach-Object { $_.Script } | Select-Object -Unique)) { [void]$cat.Groups.Add($s, $s) }
    foreach ($i in $catalogo) {
        $it = New-Object Windows.Forms.ListViewItem($i.Id, $cat.Groups[$i.Script])
        [void]$it.SubItems.Add($i.Texto)
        [void]$it.SubItems.Add($(if ($i.Aviso) { "ATENÇÃO: $($i.Aviso)  $($i.Perda)" } else { $i.Perda }))
        $it.ToolTipText = "$($i.Texto)`nPerde: $($i.Perda)$(if ($i.Aviso) { "`nATENÇÃO: $($i.Aviso)" })$(if ($i.Quando) { "`nQuando usar: $($i.Quando)" })"
        $it.Tag = $i
        if ($i.Aviso) { $it.ForeColor = $cor.Execucao }
        if ($i.Informativo) { $it.ForeColor = $cor.Pendente }
        $it.Checked = Test-PreSelecionado -Item $i
        [void]$cat.Items.Add($it)
    }
    $contar = { $rotConta.Text = "$(@($cat.CheckedItems).Count) itens marcados. Selecione um item para ver o detalhe." }
    $cat.Add_ItemCheck({ if ($cat.Items[$_.Index].Tag.Informativo) { $_.NewValue = $_.CurrentValue } })
    $cat.Add_ItemChecked({ & $contar })
    & $contar
    $detalhe = New-PilhaJanela; $detalhe.Dock = 'Bottom'; $detalhe.Height = 190; $detalhe.BackColor = $cor.Branco
    $detalhe.Padding = New-Object Windows.Forms.Padding(14, 10, 14, 6)
    $dTitulo = New-RotuloJanela -Texto '' -Fonte $fonte.Negrito -Largura 780
    $dQuando = New-RotuloJanela -Texto '' -Cor $cor.Acento -Largura 780
    $dCorrige = New-RotuloJanela -Texto '' -Largura 780
    $dPerde = New-RotuloJanela -Texto '' -Cor $cor.Texto2 -Largura 780
    $dFonte = New-RotuloJanela -Texto '' -Fonte $fonte.Pequena -Cor $cor.Pendente -Largura 780
    $detalhe.Controls.AddRange(@($dTitulo, $dQuando, $dCorrige, $dPerde, $dFonte))
    $mostrarDetalhe = {
        param($i)
        $dTitulo.Text = "$($i.Id)  $($i.Texto)"
        $dQuando.Text = "Quando usar: $($i.Quando)"
        $dCorrige.Text = "O que corrige: $($i.Corrige)"
        $dPerde.Text = "Perde: $($i.Perda)$(if ($i.Aviso) { "   ATENÇÃO: $($i.Aviso)" })"
        $dFonte.Text = "Fonte: $($i.Fonte)"
        foreach ($l in @($dQuando, $dCorrige, $dFonte)) { $l.Visible = [bool]$i.Quando }
    }
    $cat.Add_SelectedIndexChanged({ if ($cat.SelectedItems.Count) { & $mostrarDetalhe $cat.SelectedItems[0].Tag } })
    & $mostrarDetalhe $catalogo[0]
    $paginas[1].Controls.Add($cat); $paginas[1].Controls.Add($detalhe); $paginas[1].Controls.Add($topo2)

    # Passo 3: listas lidas da máquina, uma aba por item marcado que usa lista.
    $abas = New-Object Windows.Forms.TabControl; $abas.Name = 'Listas'; $abas.Dock = 'Fill'; $abas.Padding = [Drawing.Point]::new(14, 6)
    $rotListas = New-RotuloJanela -Texto '' -Cor $cor.Texto2 -Largura 800; $rotListas.Dock = 'Top'
    $tit3 = New-RotuloJanela -Texto 'Listas da máquina' -Fonte $fonte.Sub; $tit3.Dock = 'Top'
    $paginas[2].Controls.Add($abas); $paginas[2].Controls.Add($rotListas); $paginas[2].Controls.Add($tit3)

    # Passo 4: opções dos itens marcados (montado ao entrar).
    $p4 = New-PilhaJanela; $paginas[3].Controls.Add($p4)

    # Passo 5: resumo.
    $resumo = New-Object Windows.Forms.TextBox; $resumo.Name = 'Resumo'; $resumo.Multiline = $true; $resumo.ReadOnly = $true; $resumo.ScrollBars = 'Vertical'
    $resumo.Dock = 'Fill'; $resumo.Font = $fonte.Mono; $resumo.BackColor = $cor.Branco
    $tit5 = New-RotuloJanela -Texto 'Resumo' -Fonte $fonte.Sub; $tit5.Dock = 'Top'
    $paginas[4].Controls.Add($resumo); $paginas[4].Controls.Add($tit5)

    $montarListas = {
        $sid = ($radios | Where-Object Checked).Tag.Sid
        if ($w.SidListas -ne $sid) { foreach ($id in 'I1', 'I4') { $w.Abas.Remove($id) }; $w.Alvo = $null; $w.SidListas = $sid }
        $comLista = @($w.Marcados | Where-Object { $_.Opcao })
        foreach ($id in @($w.Abas.Keys)) { if (@($comLista | Where-Object Id -EQ $id).Count -eq 0) { $w.Abas.Remove($id) } }
        $abas.TabPages.Clear()
        $rotListas.Text = if ($comLista.Count) { 'Marque o que entra em cada item. Item sem nada marcado é desmarcado.' } else { 'Nenhum item marcado usa lista lida da máquina. Avance.' }
        $f.Cursor = 'WaitCursor'
        try {
            foreach ($i in $comLista) {
                if (-not $w.Abas.ContainsKey($i.Id)) {
                    $aba = New-Object Windows.Forms.TabPage($i.Id); $aba.Padding = New-Object Windows.Forms.Padding(8); $aba.BackColor = $cor.Branco
                    $grade = $null
                    try {
                        if ($i.Id -in 'I1', 'I4' -and -not $w.Alvo) { $w.Alvo = if ($sid) { Get-UsuarioAlvo -Sid $sid } else { Get-UsuarioAlvo } }
                        $lista = @(Get-ListaItem -Id $i.Id -Alvo $w.Alvo)
                        $msg = if ($lista.Count) { $i.Texto } else { 'Nada encontrado nesta máquina. O item será desmarcado.' }
                    }
                    catch { $lista = @(); $msg = "Não foi possível ler a lista ($($_.Exception.Message)). O item será desmarcado." }
                    if ($lista.Count) {
                        $grade = New-Object Windows.Forms.DataGridView
                        $grade.Dock = 'Fill'; $grade.AllowUserToAddRows = $false; $grade.AllowUserToDeleteRows = $false; $grade.RowHeadersVisible = $false
                        $grade.BackgroundColor = $cor.Branco; $grade.BorderStyle = 'None'; $grade.SelectionMode = 'FullRowSelect'; $grade.AutoSizeColumnsMode = 'Fill'
                        $grade.ColumnHeadersHeightSizeMode = 'AutoSize'; $grade.RowTemplate.Height = 30; $grade.EditMode = 'EditOnEnter'
                        $cc = New-Object Windows.Forms.DataGridViewCheckBoxColumn; $cc.HeaderText = 'Escolher'; $cc.FillWeight = 12; [void]$grade.Columns.Add($cc)
                        $ct = New-Object Windows.Forms.DataGridViewTextBoxColumn; $ct.HeaderText = 'Encontrado nesta máquina'; $ct.ReadOnly = $true; $ct.FillWeight = 70; [void]$grade.Columns.Add($ct)
                        if ($i.Id -eq 'I10') {
                            $cb = New-Object Windows.Forms.DataGridViewComboBoxColumn; $cb.HeaderText = 'Tipo de início'; $cb.FillWeight = 18
                            [void]$cb.Items.AddRange(@('Manual', 'Desativado')); [void]$grade.Columns.Add($cb)
                        }
                        foreach ($v in $lista) {
                            $n = if ($i.Id -eq 'I10') { $grade.Rows.Add($false, $v.Rotulo, 'Manual') } else { $grade.Rows.Add($false, $v.Rotulo) }
                            $grade.Rows[$n].Tag = $v
                        }
                        $aba.Controls.Add($grade)
                    }
                    $rot = New-RotuloJanela -Texto $msg -Cor $(if ($lista.Count) { $cor.Texto2 } else { $cor.Execucao }) -Largura 760; $rot.Dock = 'Top'
                    $aba.Controls.Add($rot)
                    $w.Abas[$i.Id] = [pscustomobject]@{ Aba = $aba; Grade = $grade }
                }
                $abas.TabPages.Add($w.Abas[$i.Id].Aba)
            }
        }
        finally { $f.Cursor = 'Default' }
    }

    $lerEscolhas = {
        # Valores marcados de cada lista e os textos para o resumo; no I10, serviço = Manual|Disabled.
        $escolhas = @{}; $rotulos = @{}
        foreach ($id in @($w.Abas.Keys)) {
            $g = $w.Abas[$id].Grade
            if (-not $g) { continue }
            [void]$g.EndEdit()
            $linhas = @($g.Rows | Where-Object { $_.Cells[0].Value -eq $true })
            if ($id -eq 'I10') {
                $mapa = @{}
                foreach ($r in $linhas) { $mapa[$r.Tag.Valor] = if ($r.Cells[2].Value -eq 'Desativado') { 'Disabled' } else { 'Manual' } }
                $escolhas[$id] = $mapa
                $rotulos[$id] = @($linhas | ForEach-Object { "$($_.Tag.Rotulo) = $($mapa[$_.Tag.Valor])" })
            }
            else {
                $escolhas[$id] = @($linhas | ForEach-Object { $_.Tag.Valor })
                $rotulos[$id] = @($linhas | ForEach-Object { $_.Tag.Rotulo })
            }
        }
        [pscustomobject]@{ Escolhas = $escolhas; Rotulos = $rotulos }
    }

    $guardarOpcoes = {
        foreach ($k in @($w.Opcoes.Keys)) {
            $c = $w.Opcoes[$k]
            $w.Valores[$k] = if ($c -is [Windows.Forms.CheckBox]) { $c.Checked } else { [int]$c.Value }
        }
    }

    $montarOpcoes = {
        $p4.Controls.Clear(); $w.Opcoes = @{}
        $p4.Controls.Add((New-RotuloJanela -Texto 'Opções' -Fonte $fonte.Sub))
        $ids = @($w.Marcados | ForEach-Object { $_.Id })
        $alguma = $false
        foreach ($o in @(
                @('M1', 'M1Reparar', 'Reparar a imagem do Windows se a verificação achar problema (baixa pelo Windows Update).')
                @('M2', 'M2Reparar', 'Rodar sfc /scannow se a verificação achar problema.')
                @('V5', 'V5DesligarInicializacaoRapida', 'Desligar a inicialização rápida.'))) {
            if ($ids -notcontains $o[0]) { continue }
            $alguma = $true
            $c = New-Object Windows.Forms.CheckBox; $c.Name = $o[1]; $c.Text = "$($o[0]): $($o[2])"; $c.AutoSize = $true
            $c.Margin = New-Object Windows.Forms.Padding(0, 8, 0, 4); $c.Checked = [bool]$w.Valores[$o[1]]
            $p4.Controls.Add($c); $w.Opcoes[$o[1]] = $c
            $q = ($catalogo | Where-Object Id -EQ $o[0]).Quando
            if ($q) { $r = New-RotuloJanela -Texto "Quando usar: $q" -Cor $cor.Texto2 -Largura 760; $r.Margin = New-Object Windows.Forms.Padding(18, 0, 0, 8); $p4.Controls.Add($r) }
        }
        if ($ids -contains 'M8') {
            $alguma = $true
            $t = New-RotuloJanela -Texto 'M8: horário ativo do Windows Update' -Fonte $fonte.Negrito; $t.Margin = New-Object Windows.Forms.Padding(0, 12, 0, 4)
            $p4.Controls.Add($t)
            $linha = New-Object Windows.Forms.FlowLayoutPanel; $linha.AutoSize = $true; $linha.WrapContents = $false
            $ini = New-Object Windows.Forms.NumericUpDown; $ini.Name = 'M8Inicio'; $ini.Minimum = 0; $ini.Maximum = 23; $ini.Width = 70
            $fim = New-Object Windows.Forms.NumericUpDown; $fim.Name = 'M8Fim'; $fim.Minimum = 0; $fim.Maximum = 23; $fim.Width = 70
            # Padrão do Windows: 8 h às 17 h (learn.microsoft.com: Manage device restarts after updates).
            $ini.Value = if ($w.Valores.ContainsKey('M8Inicio')) { $w.Valores['M8Inicio'] } else { 8 }
            $fim.Value = if ($w.Valores.ContainsKey('M8Fim')) { $w.Valores['M8Fim'] } else { 17 }
            $l1 = New-RotuloJanela -Texto 'Das'; $l1.Margin = New-Object Windows.Forms.Padding(0, 6, 6, 0)
            $l2 = New-RotuloJanela -Texto 'h às'; $l2.Margin = New-Object Windows.Forms.Padding(6, 6, 6, 0)
            $l3 = New-RotuloJanela -Texto 'h'; $l3.Margin = New-Object Windows.Forms.Padding(6, 6, 0, 0)
            $linha.Controls.AddRange(@($l1, $ini, $l2, $fim, $l3))
            $p4.Controls.Add($linha)
            $m8 = $catalogo | Where-Object Id -EQ 'M8'
            $p4.Controls.Add((New-RotuloJanela -Texto "Intervalo de 1 a 18 h (limite do Windows). Use o horário de trabalho do cliente. Quando usar: $($m8.Quando)" -Cor $cor.Texto2 -Largura 760))
            $w.Opcoes['M8Inicio'] = $ini; $w.Opcoes['M8Fim'] = $fim
        }
        $w.ErroOpcoes = New-RotuloJanela -Texto '' -Cor $cor.Falha; $p4.Controls.Add($w.ErroOpcoes)
        if (-not $alguma) { $p4.Controls.Add((New-RotuloJanela -Texto 'Nenhum item marcado tem opções. Avance.' -Cor $cor.Texto2)) }
    }

    $mostrar = {
        for ($i = 0; $i -lt $passos.Count; $i++) {
            $paginas[$i].Visible = ($i -eq $w.Passo)
            $rotPassos[$i].Font = if ($i -eq $w.Passo) { $fonte.Negrito } else { $fonte.Normal }
            $rotPassos[$i].ForeColor = if ($i -eq $w.Passo) { $cor.Acento } elseif ($i -lt $w.Passo) { $cor.OK } else { $cor.Pendente }
            $rotPassos[$i].Text = '{0}  {1}' -f $(if ($i -lt $w.Passo) { '✓' } else { "$($i + 1)." }), $passos[$i]
        }
        $bVoltar.Enabled = $w.Passo -gt 0
        $bAvancar.Text = if ($w.Passo -eq $passos.Count - 1) { 'Gravar perfil' } else { 'Avançar' }
    }

    $bAvancar.Add_Click({
            Invoke-AcaoJanela -Janela $f -Acao {
                switch ($w.Passo) {
                    0 {
                        $nome = $txtCliente.Text.Trim()
                        if (-not (Test-NomeCliente $nome)) { $rotErro1.Text = 'Nome inválido.'; return }
                        $rotErro1.Text = ''
                        $w.Sobrescrever = $false
                        if (Test-Path -LiteralPath (Join-Path $Pasta "$nome.psd1")) {
                            if (-not (Test-PerguntaJanela -Janela $f -Texto "Já existe perfil para $nome. Sobrescrever?" -Titulo 'Novo perfil')) { return }
                            $w.Sobrescrever = $true
                        }
                    }
                    1 {
                        $w.Marcados = @($cat.CheckedItems | ForEach-Object { $_.Tag } | Where-Object { -not $_.Informativo })
                        if (-not $w.Marcados.Count) { Show-AvisoJanela -Janela $f -Texto 'Marque ao menos um item.' -Titulo 'Novo perfil'; return }
                        & $montarListas
                    }
                    2 { & $montarOpcoes }
                    3 {
                        & $guardarOpcoes
                        if ($w.Opcoes.ContainsKey('M8Inicio') -and -not (Test-HorarioM8 -Inicio $w.Valores['M8Inicio'] -Fim $w.Valores['M8Fim'])) {
                            $w.ErroOpcoes.Text = 'M8: intervalo de 1 a 18 h (limite do Windows).'; return
                        }
                        $lido = & $lerEscolhas
                        $opcoes = @{}; foreach ($k in @($w.Opcoes.Keys)) { $opcoes[$k] = $w.Valores[$k] }
                        $u = ($radios | Where-Object Checked).Tag
                        $w.Resultado = New-DadosPerfil -Cliente $txtCliente.Text.Trim() -UsuarioSid $u.Sid -Marcados @($w.Marcados | ForEach-Object { $_.Id }) -Escolhas $lido.Escolhas -Opcoes $opcoes
                        $resumo.Text = (Get-ResumoPerfil -Dados $w.Resultado.Dados -Usuario $u.Nome -Rotulos $lido.Rotulos -Desmarcados $w.Resultado.Desmarcados) -join "`r`n"
                    }
                    4 {
                        if (-not @($w.Resultado.Dados.Aplicar).Count) { Show-AvisoJanela -Janela $f -Texto 'Nenhum item restou marcado. Nada foi gravado.' -Titulo 'Novo perfil'; return }
                        $w.Arquivo = Save-PerfilGerado -Dados $w.Resultado.Dados -Pasta $Pasta -Force:$w.Sobrescrever
                        $f.DialogResult = 'OK'
                        return
                    }
                }
                $w.Passo++
                & $mostrar
            }
        })
    $bVoltar.Add_Click({
            if ($w.Passo -eq 3) { & $guardarOpcoes }
            $w.Passo--; & $mostrar
        })
    $bCancelar.Add_Click({ $f.Close() })
    $f.Add_FormClosing({
            if ($f.DialogResult -ne 'OK' -and -not (Test-PerguntaJanela -Janela $f -Texto 'Cancelar o novo perfil? Nada será gravado.' -Titulo 'Novo perfil')) { $_.Cancel = $true }
        })

    $f.Controls.Add($conteudo); $f.Controls.Add($lado); $f.Controls.Add($rodape)
    & $mostrar
    $f.Tag = $w
    [void]$f.ShowDialog()
    $f.Dispose()
    $w.Arquivo
}

#endregion
