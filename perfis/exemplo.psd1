# Perfil de cliente. Lido com Import-PowerShellDataFile: apenas dados, nenhum código é executado.
# Copie para perfis\<Cliente>.psd1 e mantenha em Aplicar somente os itens aprovados para este cliente.
@{
    # Nome do cliente: usado na pasta de backup %ProgramData%\Otimizacao\<Cliente>. Letras, números, ponto, hífen, sublinhado.
    Cliente    = 'Exemplo'

    # SID do usuário cujo HKCU será alterado. Vazio = usuário conectado ao console.
    # Descobrir: (Get-CimInstance Win32_UserProfile | Where-Object LocalPath -like '*\joao').SID
    UsuarioSid = ''

    # Itens do catálogo a aplicar. L4 a L7 exigem aprovação específica do cliente. A1 aprova a lista base inteira de apps de consumo
    # (exceções em Protegidos.Aplicativos); A2 só remove o que estiver em Opcoes.A2Remover.
    Aplicar    = @(
        'L1', 'L2', 'L3', 'L8', 'L9'
    )

    # Itens a não aplicar mesmo se listados acima.
    Pular      = @()

    # Nunca tocar. Aceita curingas (*). Categorias usadas pelos scripts de inicialização, serviços, tarefas e aplicativos.
    # Aplicativos: nome do pacote (ex.: 'Microsoft.BingWeather') ou nome de exibição (ex.: 'MSN Weather').
    Protegidos = @{
        Inicializacao = @()
        Servicos      = @()
        Tarefas       = @()
        Aplicativos   = @()
    }

    # Opções por script. Listas vazias: o item correspondente é pulado.
    Opcoes     = @{
        # VisualEnergia V5: desligar a inicialização rápida (padrão: mantida).
        V5DesligarInicializacaoRapida = $false
        # Inicializacao I1: entradas de inicialização a desabilitar, com o Nome como aparece na Coleta.
        I1Desabilitar       = @()
        # Inicializacao I4: apps da Store sem execução em segundo plano (Package Family Name).
        I4NegarSegundoPlano = @()
        # Inicializacao I9: tarefas agendadas de terceiros a desabilitar ('\Pasta\Nome').
        I9Tarefas           = @()
        # Inicializacao I10: serviços de terceiros e tipo de início desejado ('Manual' ou 'Disabled').
        I10Servicos         = @{}
        # Manutencao M1 e M2: reparar se a verificação achar problema (padrão: só verificar). M1 baixa arquivos pelo Windows Update.
        M1Reparar           = $false
        M2Reparar           = $false
        # Manutencao M8: horário ativo do Windows Update (horas 0 a 23, intervalo de 1 a 18 h). Sem os dois, M8 é pulado.
        # M8Inicio          = 7
        # M8Fim             = 19
        # Aplicativos A2: programas do fabricante aprovados para remoção, com o Nome da seção Programas da Coleta (aceita *).
        A2Remover           = @()
    }
}
