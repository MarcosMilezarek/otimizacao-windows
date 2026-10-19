<#
.SYNOPSIS
    Lancador do projeto de otimizacao: baixa os scripts de um commit fixo do GitHub, confere o SHA256 de cada arquivo e
    abre o Menu.

.DESCRIPTION
    Uso, no PowerShell aberto como administrador (o comando exato de cada versao e impresso por tools\Publicar.ps1):

        [Net.ServicePointManager]::SecurityProtocol='Tls12'; irm https://raw.githubusercontent.com/marcosmilezarek/otimizacao-windows/<commit>/Iniciar.ps1 | iex

    1. Aborta sem administrador, antes de baixar qualquer coisa.
    2. Baixa cada arquivo da tabela abaixo do commit indicado para C:\ProgramData\Otimizacao\app\.baixando-<sha7>,
       confere o SHA256 e so entao renomeia para C:\ProgramData\Otimizacao\app\<sha7>. Qualquer divergencia ou falha
       apaga a pasta temporaria e aborta sem executar nada. Pasta final ja integra: nao baixa de novo.
    3. Restringe C:\ProgramData\Otimizacao a SYSTEM e Administradores (Usuarios: leitura), como o Menu.
    4. Abre o Menu em processo novo com -ExecutionPolicy Bypass (vale so para esse processo).

    O que altera: cria C:\ProgramData\Otimizacao\app\<sha7>. Nao cria tarefa, servico nem atalho.
    Reversao: apagar a pasta app\<sha7>. Os scripts baixados continuam sem acesso a internet.

    Arquivo em ASCII sem BOM: o Invoke-Expression falha com o BOM no inicio do texto. Acentos das mensagens via [char].
#>

# <publicacao>
$script:RepoIniciar = 'marcosmilezarek/otimizacao-windows'
$script:CommitIniciar = 'f8bd5bb6b2fc1e90c2f6952cb2e07061a133a163'
$script:ArquivosIniciar = [ordered]@{
    'perfis/exemplo.psd1' = 'CA79948FBBC78670B05DEB49C4C2AADEE5293896C5C2C0ADB407154818D71AA1'
    'src/Aplicativos.ps1' = 'DB65C5668C42D5F9F282BEEBA072ED51E00CFA2AE9E99537AE1A7D003D57BAFC'
    'src/Coleta.ps1' = 'BABF5360FDAFC1813A65A2E47198B8AA2460257D404A7F23FBCC7FA207158EA0'
    'src/Inicializacao.ps1' = '80D6B7FB5C732F574E08C7EBFE2807BA55256311BD127132F681E90AACEE7612'
    'src/Limpeza.ps1' = '334F2562796C533442ECF80D5E62833684B22FA0E4F38C16C939841D43E64DCD'
    'src/Manutencao.ps1' = '1C31159EE86F09668209AD693126B495FBB4D0A668214367ED870B86BEEDD628'
    'src/Menu.ps1' = 'B31B2D837111AD9E33243B8BB75E0F7F350C26B041D32D0574D63BF402A300EA'
    'src/Otimizacao.Comum.psm1' = '852DE814B291EB7FA81457E1AB764C7CC9300107C846EE07F2AD70F00CA47D43'
    'src/Perfil.ps1' = 'AB790354138E5C8D3C812B86BF16BA8560A3A59790AB4C5A75991D7C13AC8AFC'
    'src/Verificacao.ps1' = 'C1D3D0FE8EA28CBB13485B91E0488F8E8C177C0DE3A6002AC5458F6CE4EEAC5C'
    'src/VisualEnergia.ps1' = '8EAA84481D887B9DF15D33FF902FD67CBFE71E390EDF2DA1EA39A34B7D967EEE'
}
# </publicacao>

function Test-AdministradorIniciar {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-HashArquivoIniciar {
    param([Parameter(Mandatory)][string]$Caminho)
    (Get-FileHash -LiteralPath $Caminho -Algorithm SHA256).Hash
}

function Test-PastaIntegra {
    <# Verdadeiro se todos os arquivos da tabela existem na pasta com o SHA256 esperado. #>
    param([Parameter(Mandatory)][string]$Pasta, [Parameter(Mandatory)][Collections.IDictionary]$Arquivos)
    foreach ($rel in $Arquivos.Keys) {
        $a = Join-Path $Pasta ($rel -replace '/', '\')
        if (-not (Test-Path -LiteralPath $a -PathType Leaf)) { return $false }
        if ((Get-HashArquivoIniciar $a) -ne $Arquivos[$rel]) { return $false }
    }
    $true
}

function Assert-SemJuncaoIniciar {
    <# Recusa pasta que seja juncao ou link: apagar ou gravar nela atingiria outro lugar com a conta de administrador. #>
    param([Parameter(Mandatory)][string]$Caminho)
    $item = Get-Item -LiteralPath $Caminho -Force -ErrorAction SilentlyContinue
    if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "$Caminho e uma juncao ou link simbolico. Abortado sem baixar nem apagar nada."
    }
}

function Get-EstadoAcl {
    <# Dono e regras de acesso (por SID) de um arquivo ou pasta. #>
    param([Parameter(Mandatory)][string]$Caminho)
    $acl = Get-Acl -LiteralPath $Caminho
    [pscustomobject]@{
        Dono   = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
        Regras = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | ForEach-Object {
                [pscustomobject]@{ Sid = $_.IdentityReference.Value; Direitos = [int]$_.FileSystemRights; Tipo = [string]$_.AccessControlType }
            })
    }
}

function Test-AclSegura {
    <#
        Verdadeiro se o dono e Administradores ou SYSTEM e so SYSTEM, Administradores e Usuarios tem permissao, Usuarios
        sem gravar, apagar ou mudar permissao. Sem isso um usuario comum poderia trocar um script que roda elevado.
    #>
    param([Parameter(Mandatory)][string]$Caminho)
    $estado = Get-EstadoAcl -Caminho $Caminho
    if ($estado.Dono -notin 'S-1-5-32-544', 'S-1-5-18') { return $false }
    $gravacao = [int][Security.AccessControl.FileSystemRights]'WriteData, AppendData, WriteExtendedAttributes, DeleteSubdirectoriesAndFiles, WriteAttributes, Delete, ChangePermissions, TakeOwnership'
    foreach ($r in @($estado.Regras | Where-Object { $_.Tipo -eq 'Allow' })) {
        if ($r.Sid -notin 'S-1-5-18', 'S-1-5-32-544', 'S-1-5-32-545') { return $false }
        # 0x40000000 = GENERIC_WRITE e 0x10000000 = GENERIC_ALL (regras so de heranca).
        if ($r.Sid -eq 'S-1-5-32-545' -and ($r.Direitos -band ($gravacao -bor 0x50000000))) { return $false }
    }
    $true
}

function Install-ProjetoIniciar {
    <# Baixa e confere os arquivos do commit; devolve a pasta final <Raiz>\app\<sha7>. #>
    param(
        [Parameter(Mandatory)][string]$Raiz,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Commit,
        [Parameter(Mandatory)][Collections.IDictionary]$Arquivos
    )
    $curto = $Commit.Substring(0, 7)
    $app = Join-Path $Raiz 'app'
    $final = Join-Path $app $curto
    $temp = Join-Path $app ".baixando-$curto"
    foreach ($p in $Raiz, $app, $final, $temp) { Assert-SemJuncaoIniciar -Caminho $p }
    if ((Test-Path -LiteralPath $final) -and (Test-PastaIntegra -Pasta $final -Arquivos $Arquivos)) { return $final }
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
    New-Item -ItemType Directory -Path $temp -Force | Out-Null
    try {
        foreach ($rel in $Arquivos.Keys) {
            $destino = Join-Path $temp ($rel -replace '/', '\')
            New-Item -ItemType Directory -Path (Split-Path -Parent $destino) -Force | Out-Null
            try { Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/$Repo/$Commit/$rel" -OutFile $destino -ErrorAction Stop }
            catch { throw "Falha ao baixar ${rel}: $($_.Exception.Message)" }
            $hash = Get-HashArquivoIniciar $destino
            if ($hash -ne $Arquivos[$rel]) { throw "SHA256 divergente em $rel (esperado $($Arquivos[$rel]), recebido $hash). Nada foi executado." }
        }
        if (Test-Path -LiteralPath $final) { Remove-Item -LiteralPath $final -Recurse -Force }
        Rename-Item -LiteralPath $temp -NewName $curto
    }
    catch {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
    $final
}

function Set-AcessoRestritoIniciar {
    <#
        Mesmo criterio do Menu (Set-AcessoRestrito): SYSTEM e Administradores com controle total, Usuarios com leitura.
        Antes, Administradores viram donos de tudo (quem cria em ProgramData fica dono e pode mudar a ACL) e os itens
        internos voltam a herdar so da raiz, descartando permissoes explicitas.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Pasta do proprio projeto.')]
    param([Parameter(Mandatory)][string]$Pasta)
    $icacls = "$env:windir\System32\icacls.exe"
    & $icacls $Pasta /setowner '*S-1-5-32-544' /T /C /Q | Out-Null
    & $icacls $Pasta /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls falhou em $Pasta (codigo $LASTEXITCODE)." }
    if (@(Get-ChildItem -LiteralPath $Pasta -Force -ErrorAction SilentlyContinue).Count) { & $icacls (Join-Path $Pasta '*') /reset /T /C /Q | Out-Null }
}

function Start-Iniciar {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Executado so pelo comando do usuario; o Menu tem a propria simulacao.')]
    param()
    if (-not (Test-AdministradorIniciar)) {
        throw "Abra o PowerShell como administrador (bot$([char]0xE3)o direito, Executar como administrador) e repita o comando."
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $raiz = Join-Path $env:ProgramData 'Otimizacao'
    Assert-SemJuncaoIniciar -Caminho $raiz
    if (-not (Test-Path -LiteralPath $raiz)) { New-Item -ItemType Directory -Path $raiz -Force | Out-Null }
    Set-AcessoRestritoIniciar -Pasta $raiz
    Write-Output "Baixando a vers$([char]0xE3)o $($script:CommitIniciar.Substring(0, 7)) e conferindo SHA256..."
    $pasta = Install-ProjetoIniciar -Raiz $raiz -Repo $script:RepoIniciar -Commit $script:CommitIniciar -Arquivos $script:ArquivosIniciar
    # Os arquivos conferidos so continuam confiaveis se um usuario comum nao puder troca-los depois.
    $inseguros = @(@($raiz, $pasta) + @(Get-ChildItem -LiteralPath $pasta -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }) |
            Where-Object { -not (Test-AclSegura -Caminho $_) })
    if ($inseguros.Count) { throw "Permiss$([char]0xF5)es inseguras em $($inseguros[0]) (dono ou acesso fora de SYSTEM e Administradores). O Menu n$([char]0xE3)o foi aberto." }
    Write-Output "Arquivos conferidos em $pasta. Abrindo o Menu."
    $menu = Join-Path $pasta 'src\Menu.ps1'
    Start-Process -FilePath (Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList @('-NoProfile', '-ExecutionPolicy Bypass', "-File `"$menu`"") -Wait -NoNewWindow
}

# Os testes definem $OtimizacaoIniciarSemExecutar antes do dot-source. Via iex a variavel nao existe e o lancador roda.
if (-not (Get-Variable -Name OtimizacaoIniciarSemExecutar -ValueOnly -ErrorAction SilentlyContinue)) { Start-Iniciar }
