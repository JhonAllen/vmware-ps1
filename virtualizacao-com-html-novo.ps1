# Connect vCenter
#Insira os dados do seu vcenter aqui
$server = "p"
# Usuário de authenticação no vcenter
$username = ""
# Senha
$password = ""

# Verifica se o módulo VMware.PowerCLI está instalado
if (-not (Get-Module -Name VMware.PowerCLI -ListAvailable)) {
    # Se não estiver instalado, instala o módulo
    Write-Host "Instalando o módulo VMware.PowerCLI..."
    Install-Module VMware.PowerCLI -Force -AllowClobber
}

# Verifica se o módulo VMware.PowerCLI está importado
if (-not (Get-Module -Name VMware.PowerCLI)) {
    # Se não estiver importado, importa o módulo
    Write-Host "Importando o módulo VMware.PowerCLI..."
    Import-Module VMware.PowerCLI -Force
} else {
    Write-Host "O módulo VMware.PowerCLI já está importado."
}
Set-PowerCLIConfiguration -Scope User -ParticipateInCEIP $false -Confirm:$false

# Tenta se conectar ao servidor vCenter
try {
    Write-Host "Conectando ao servidor vCenter..."
    Connect-VIServer -Server $server -User $username -Password $password -ErrorAction Stop
    Write-Host "Conexão bem-sucedida ao servidor vCenter."
} catch {
    Write-Host "Não foi possível se conectar ao servidor vCenter. Verifique suas credenciais e o endereço do servidor."
}

# Obter dados das VM's e aplicar filtro
# Obter informações das VMs e também determinando se são Linux ou Windows com base no GuestOS
$vmInfo = Get-VM |
    Where-Object { $_.Name -notlike "vCLS*" } |
    Select-Object Name,
        @{Name="GuestOS"; Expression={$_.Guest.OSFullName}},
        NumCpu,
        MemoryGB,
        @{Name="Description"; Expression={$_.ExtensionData.Summary.Config.Annotation}},
        @{Name="Host"; Expression={(Get-VMHost -VM $_).Name}},
        @{Name="Data de Criação"; Expression={$_.ExtensionData.Config.CreateDate}},
        @{Name="Tipo"; Expression={
            $osFullName = $_.Guest.OSFullName
            if ($osFullName -match "Windows") {
                "Windows"
                }
            else {
                "Linux"
            }
        }},
        @{Name="Tamanho do Disco (GB)"; Expression={
            $vm = $_
            $diskUsage = $_ | Get-HardDisk | Measure-Object -Property CapacityGB -Sum
            $diskUsage.Sum
        }},
        @{Name="Estado"; Expression={$_.PowerState}}

$desligadas = ($vmInfo | Where-Object { $_.Estado -eq "PoweredOff" }).Count

# Contadores para quantidades de VM's
$totalVMs = $vmInfo.Count
$countLinuxVMs = ($vmInfo | Where-Object { $_.Tipo -eq "Linux" }).Count
$countWindowsVMs = ($vmInfo | Where-Object { $_.Tipo -eq "Windows" }).Count


# Calcular porcentagens
$percentLinux = [math]::Round(($countLinuxVMs / $totalVMs) * 100)
$percentWindows = [math]::Round(($countWindowsVMs / $totalVMs) * 100)



# Obter dados dos Hosts Físicos
$hostInfo = Get-VMHost |
    Select-Object Name, ConnectionState, PowerState,
        @{Name="CpuTotalGhz"; Expression={[math]::Round($_.CpuTotalMhz / 1000, 2)}},
        @{Name="CpuTotalMhz"; Expression={[math]::Round($_.CpuTotalMhz)}},
        @{Name="CpuUsageGhz"; Expression={[math]::Round($_.CpuUsageMhz / 1000, 2)}},
        @{Name="MemoryUsageGB"; Expression={[math]::Round($_.MemoryUsageGB)}},
        @{Name="MemoryTotalGB"; Expression={[math]::Round($_.MemoryTotalGB)}},
        Version

# Calcula o total de memória de todos os hosts
$totalMemoryGB = ($hostInfo | Measure-Object -Property MemoryTotalGB -Sum).Sum

# Calcula o total de memória utilizada de todos os hosts
$totalMemoryUsedGB = ($hostInfo | Measure-Object -Property MemoryUsageGB -Sum).Sum

# Obtém mais dados dos Hosts Físicos
$hostHardware = Get-VMHost | ForEach-Object {
    $currentHost = $_
    Get-VMHostHardware -VMHost $currentHost | Select-Object `
        @{Name="HostName";Expression={$currentHost.Name}},
        CpuCoreCountTotal,
        Manufacturer,
        Model,
        SerialNumber,
        NicCount,
        @{
            Name = "CpuModel";
            Expression = {
                if ($_.CpuModel -like "*Intel*") {
                    "Intel"
                }
                elseif ($_.CpuModel -like "*AMD*") {
                    "AMD"
                }
                else {
                    $_.CpuModel
                }
            }
        },
        @{
            Name = "CPUSpeed";
            Expression = {
                switch -Wildcard ($_.CpuModel) {
                    "*Intel(R) Xeon(R) Gold 6152 CPU @ 2.10GHz*" { "2.10 GHz" }
                    "*AMD Opteron(tm) Processor 6282 SE*" { "2.6 GHz" }
                    "*Intel(R) Xeon(R) CPU E5-2650 0 @ 2.00GHz*" { "2.00 GHz" }
                    "*Intel(R) Xeon(R) CPU           X7550  @ 2.00GHz*" { "2.00 GHz" }
                    default { $_.CpuModel }
                }
            }
        }
} | Sort-Object HostName

$vcenter = Get-View ServiceInstance

$vcenterDetails = @{
    Version = $vcenter.Content.About.Version
    Build = $vcenter.Content.About.Build
    ApiVersion = $vcenter.Content.About.ApiVersion
    InstanceUuid = $vcenter.Content.About.InstanceUuid
    OsType = $vcenter.Content.About.OsType
}

# Obter os datastores que começam com "SP_A"
$datastores = Get-Datastore | Where-Object {$_.Name -like "SP_A*"}

# Inicializar variáveis para armazenar as informações de armazenamento
$totalStorageTB = 0
$usedStorageTB = 0

# Loop pelos datastores filtrados
foreach ($ds in $datastores) {
    # Calcular o total de armazenamento em TB
    $totalTB = [math]::Round($ds.CapacityGB / 1024, 2)
    $totalStorageTB += $totalTB
    
    # Calcular o armazenamento utilizado em TB
    $usedTB = [math]::Round(($ds.CapacityGB - $ds.FreeSpaceGB) / 1024, 2)
    $usedStorageTB += $usedTB

    # Exibir informações do datastore atual
    Write-Output "Datastore: $($ds.Name)"
    Write-Output "   Total de armazenamento: $totalTB TB"
    Write-Output "   Armazenamento utilizado: $usedTB TB"
    Write-Output "   Porcentagem utilizada: $([math]::Round(($usedTB / $totalTB) * 100, 2))%"
    Write-Output ""
}




# Criação do HTML
$htmlContent = @"
<!doctype html>
<html lang="en" class="h-100">
<head>
  <meta charset="utf-8">
  <link rel="apple-touch-icon" type="image/png" href="https://raw.githubusercontent.com/luanfelixcoelho/img/4493964c3e6ae9d153a2dbddf8387fe055d2f80e/favicon-saturnosys.svg">
  <meta name="apple-mobile-web-app-title" content="CodePen">
  <link rel="shortcut icon" type="image/x-icon" href="https://raw.githubusercontent.com/luanfelixcoelho/img/4493964c3e6ae9d153a2dbddf8387fe055d2f80e/favicon-saturnosys.svg">
  <link rel="mask-icon" type="image/x-icon" href="https://raw.githubusercontent.com/luanfelixcoelho/img/4493964c3e6ae9d153a2dbddf8387fe055d2f80e/favicon-saturnosys.svg" color="#111">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="description" content="">
  <title>SOF | Virtualização</title>

  <link rel="canonical" href="https://getbootstrap.com/docs/5.3/examples/sticky-footer-navbar/">
  <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@docsearch/css@3">
  <link href="../css/bootstrap.min.css" rel="stylesheet">
  <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.1/css/all.min.css" integrity="sha512-DTOQO9RWCH3ppGqcWaEA1BIZOC6xxalwEsw9c2QQeAIftl+Vegovlnee1c9QX4TctnWMn13TZye+giMm8e2LwA==" crossorigin="anonymous" referrerpolicy="no-referrer" />
  <link charset="UTF-8" href="../css/sticky-footer-navbar.css" rel="stylesheet">
  <link href="../css/vmm.css" rel="stylesheet">
  
  <!-- Data Table CSS -->
  <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/twitter-bootstrap/5.3.0/css/bootstrap.min.css">
  <link rel="stylesheet" href="https://cdn.datatables.net/2.0.0/css/dataTables.bootstrap5.css">
  <link rel="stylesheet" href="https://cdn.datatables.net/searchbuilder/1.7.0/css/searchBuilder.bootstrap5.css">
  <link rel="stylesheet" href="https://cdn.datatables.net/buttons/3.0.0/css/buttons.bootstrap5.css">
  
  <style>
    .section-header {
      background-color: #3c8095;
      color: white;
      padding: 10px;
      margin-top: 30px;
      margin-bottom: 10px;
      border-radius: 5px;
      font-weight: bold;
    }
    .table-container {
      margin-top: 20px;
    }
  </style>
</head>

<body class="d-flex flex-column h-100" style="background-color: #5858581f;">

  <header>
    <nav class="navbar navbar-expand-md navbar-dark fixed-top bg-dark">
      <div class="container-fluid">
        <a class="navbar-brand" href="http://infrati.sof.intra">Menu</a>
        <button class="navbar-toggler" type="button" data-bs-toggle="collapse" data-bs-target="#navbarNav" aria-controls="navbarNav" aria-expanded="false" aria-label="Toggle navigation">
          <span class="navbar-toggler-icon"></span>
        </button>
        <div class="collapse navbar-collapse" id="navbarNav">
          <ul class="navbar-nav">
            <li class="nav-item">
              <a class="nav-link" href="ad.html">Active Directory</a>
            </li>
            <li class="nav-item">
              <a class="nav-link" aria-current="page" href="storage.html">Storage</a>
            </li>
            <li class="nav-item">
              <a class="nav-link active" href="vmware.html">Virtualização</a>
            </li>
            <li class="nav-item">
              <a class="nav-link" href="invent_comp.html">Computadores</a>
            </li>
          </ul>
        </div>
      </div>
    </nav>
  </header>

  <main class="flex-shrink-0">
    <div class="container">
      <div class="my-3 p-3 bg-body rounded shadow-sm">
        <img class="fit-picture" src="../img/vmware3.png" alt="Microsoft 365" style="margin-right: 20px;margin-bottom: 120px;margin-top: 30px; float: left;height: 200px;">
        <h2 class="border-bottom pb-2 mb-0">VMware vCenter</h2>

        <div class="row" style="margin-top: 20px;">
          <div class="col-sm-3">
            <div class="card text-bg-dark" style="background-color: rgb(46, 138, 243) !important;">
              <div class="card-body">
                <h5 class="card-title">Máquinas Virtuais</h5>
                <p class="card-text text-center fs-1">$($totalVMs)</p>
              </div>
            </div>
          </div>
          <div class="col-sm-3">
            <div class="card text-bg-dark" style="background-color: rgb(201 3 71) !important;">
              <div class="card-body">
                <h5 class="card-title">VMs Desligadas</h5>
                <p class="card-text text-center fs-1">$($desligadas)</p>
              </div>
            </div>
          </div>
          <div class="col-sm-3">
            <div class="card" style="background-color: rgb(243, 181, 46) !important;">
              <div class="card-body">
                <h5 class="card-title">Hosts</h5>
                <p class="card-text text-center fs-1">26</p>
              </div>
            </div>
          </div>        
        </div>

        <div class="row" style="margin-top: 20px;">
          <div class="col-sm-4 mb-4 mb-sm-0">
            <div class="card">
              <div class="card-body">
                <h5 class="card-title">Detalhes do vCenter</h5>
                <p class="card-text">
                  <b>Host ::</b> pvcn01.sof.intra<br>
                  <b>Versão ::</b> $($vcenter.Content.About.Version)<br>
                  <b>Build ::</b> $($vcenter.Content.About.Build)<br>
                  <b>Sistema Operacional  ::</b> $($vcenter.Content.About.OsType)<br>
                </p>
              </div>
            </div>
          </div>

          <div class="col-sm-4 mb-4 mb-sm-0">
            <div class="card">
              <div class="card-body">
                <h5 class="card-title">Recursos Disponíveis</h5>
                <div class="container">
                  <div class="row mt-3">
                    <div class="col-md-6 col-sm-6">
                      <strong class="d-block h6 mb-2">Memória (GB)</strong>
                      <span class="text-secondary">$($totalMemoryUsedGB) de $($totalMemoryGB)</span>
                      <div class="progress mt-2" style="height: 30px;">
                        <div class="progress-bar" role="progressbar" style="width: 53%;" aria-valuenow="53" aria-valuemin="0" aria-valuemax="100">53%</div>
                      </div>
                    </div>
                    <div class="col-md-6 col-sm-6">
                      <strong class="d-block h6 mb-2">Storage (TB)</strong>
                      <span class="text-secondary">$($usedStorageTB) de $($totalStorageTB)</span>
                      <div class="progress mt-2" style="height: 30px;">
                        <div class="progress-bar" role="progressbar" style="width: 68%; background-color: #b95495 !important;" aria-valuenow="68" aria-valuemin="0" aria-valuemax="100">$([math]::Round(($usedStorageTB / $totalStorageTB) * 100))%</div>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>
          

          <div class="col-sm-4 mb-4 mb-sm-0">
            <div class="card">
              <div class="card-body">
                <h5 class="card-title">Sistemas Operacionais</h5>
                <div class="container">
                  <div class="row" style="margin-top: 30px;">
                    <div class="col-md-6 col-sm-6">
                      <strong class="d-block h6 mb-0">Windows</strong>
                      <span class="text-secondary">$($countWindowsVMs)</span>
                    </div>
                    <div class="col-md-6 col-sm-6">
                      <strong class="d-block h6 mb-0">Linux</strong>
                      <span class="text-secondary">$($countLinuxVMs)</span>
                    </div>
                
                  </div>
                  <div class="progress-stacked" style="height: 30px;">
                    <div class="progress" role="progressbar" aria-label="Segment one" aria-valuenow="56" aria-valuemin="0"
                      aria-valuemax="269" style="width: 21%; height: 30px;">
                      <div class="progress-bar">$($percentWindows)%</div>
                    </div>
                    <div class="progress" role="progressbar" aria-label="Segment two" aria-valuenow="210" aria-valuemin="0"
                      aria-valuemax="269" style="width: 78%; height: 30px;">
                      <div class="progress-bar bg-warning" style="color: black;">$($percentLinux)%</div>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>
          
        </div>

        <h6 class="section-header">Informações dos Hosts</h6>
        <div class="table-container">
          <table id="hosts" class="table table-striped table-bordered" style="width:100%">
            <thead>
              <tr>
                <th>Nome</th>
                <th>Estado de Conexão</th>
                <th>Estado de Energia</th>
                <th>ESXi</th>
                <th>Total CPU (GHz)</th>
                <th>Uso CPU (GHz)</th>
                <th>Uso Memória (GB)</th>                
                <th>Total Memória (GB)</th>
              </tr>
            </thead>
            <tbody class="table-group-divider">
"@

foreach ($hosts in $hostInfo) {
$htmlContent += @"
              <tr>
                <td>$($hosts.Name)</td>
                <td>$($hosts.ConnectionState)</td>
                <td>$($hosts.PowerState)</td>
                <td>$($hosts.Version)</td>
                <td>$($hosts.CpuTotalGhz)</td>
                <td>$($hosts.CpuUsageGhz)</td>
                <td>$($hosts.MemoryUsageGB)</td>
                <td>$($hosts.MemoryTotalGB)</td>
              </tr>
"@
}

$htmlContent += @"
            </tbody>
          </table>
        </div>

        <h6 class="section-header">Detalhes do Hardware dos Hosts</h6>
        <div class="table-container">
          <table id="vm" class="table table-striped table-bordered" style="width:100%">
            <thead>
              <tr>
                <th>Host</th>
                <th>Modelo</th>
                <th>Fabricante</th>
                <th>Número de NICs</th>
                <th>Núcleos CPU</th>
                <th>Modelo CPU</th>
                <th>Velocidade CPU</th>
                <th>Número de Série</th>             
              </tr>
            </thead>
            <tbody>
"@

foreach ($hardware in $hostHardware) {
$htmlContent += @"
              <tr>
                <td>$($hardware.HostName)</td>
                <td>$($hardware.Model)</td>
                <td>$($hardware.Manufacturer)</td>
                <td>$($hardware.NicCount)</td>
                <td>$($hardware.CpuCoreCountTotal)</td>
                <td>$($hardware.CpuModel)</td>
                <td>$($hardware.CPUSpeed)</td>
                <td>$($hardware.SerialNumber)</td>
              </tr>
"@
}

$htmlContent += @"
            </tbody>
          </table>
        </div>


        <small class="d-inline-flex mb-3 px-2 py-1 fw-semibold text-light border rounded-2" style="background-color: #3c8095;width: 100%;margin-top: 30px;margin-bottom: unset !important;white-space: pre;">Relação de Servidores Virtuais</small>
        <table id="vms" class="table table-striped wrap" style="width:100%; font-size: 12px">
          <thead>
            <tr>
              <th>Nome</th>
              <th>Estado</th>
              <th>Sistema Operacional</th>
              <th>Núm. CPUs</th>
              <th>Memória (GB)</th>
              <th>Descrição</th>
              <th>Host</th>
              <th>Data de Criação</th>
              <th>Tamanho do Disco (GB)</th>
            </tr>
          </thead>
          <tbody>
"@

foreach ($vm in $vmInfo) {
    $htmlContent += @"
              <tr>
                <td>$($vm.Name)</td>
                <td>$($vm.Estado)</td>
                <td>$($vm.GuestOS)</td>
                <td>$($vm.NumCpu)</td>
                <td>$($vm.MemoryGB)</td>
                <td>$($vm.Description)</td>
                <td>$($vm.Host)</td>
                <td>$($vm.'Data de Criação')</td>
                <td>$($vm.'Tamanho do Disco (GB)')</td>
              </tr>
"@
}

$htmlContent += @"
          </tbody>
        </table>
      </div>
    </div>
  </main>

  <footer class="footer mt-auto py-3 bg-dark">
    <div class="container text-center">
      <small>Secretaria de Orçamento Federal - SOF</small>
      <div>
        <small>INFRA TI - VMware Group - 2024</small>
      </div>      
  </footer>

  <script src="https://cdn.jsdelivr.net/npm/@docsearch/js@3"></script>
  <script src="../js/bootstrap.bundle.min.js"></script>

  <!-- Data Table JS -->
  <script src="https://cdnjs.cloudflare.com/ajax/libs/jquery/3.6.4/jquery.min.js"></script>
  <script src="https://cdn.datatables.net/2.0.0/js/jquery.dataTables.js"></script>
  <script src="https://cdn.datatables.net/2.0.0/js/dataTables.bootstrap5.js"></script>
  <script src="https://cdn.datatables.net/searchbuilder/1.7.0/js/dataTables.searchBuilder.js"></script>
  <script src="https://cdn.datatables.net/searchbuilder/1.7.0/js/searchBuilder.bootstrap5.js"></script>
  <script src="https://cdn.datatables.net/buttons/3.0.0/js/dataTables.buttons.js"></script>
  <script src="https://cdn.datatables.net/buttons/3.0.0/js/buttons.bootstrap5.js"></script>

  <script>
    $(document).ready(function() {
      $('#vmTable').DataTable();
      $('#hardwareTable').DataTable();
    });
  </script>
</body>
</html>

  
  <!-- Footer -->
  <footer class="footer mt-auto py-3 bg-dark text-white-50">
    <div class="container text-center">
      <small>Secretaria de Orçamento Federal - SOF</small>
      <div>
        <small>INFRA TI - Storage Group - 2024</small>
      </div>
    </div>
    <span style="margin: 0px 5px 0px 0px; float: right; color: rgba(189, 189, 189, 0.699); font-size: 10px;">Atualizado em: 10/06/2024 17:14</span>
  </footer>


  <script charset="UTF-8" type="text/javascript" src="https://infrati.cultura.gov.br/js/canvasjs.min.js"></script>
  <script charset="utf-8" src="../js/bootstrap.bundle.min.js"></script>
  
  <!-- Data Table JS -->
  <script charset="utf-8" src='https://code.jquery.com/jquery-3.7.1.js'></script>
  <script charset="utf-8"
    src='https://cdnjs.cloudflare.com/ajax/libs/twitter-bootstrap/5.3.0/js/bootstrap.bundle.min.js'></script>
  <script charset="utf-8" src='https://cdn.datatables.net/2.0.0/js/dataTables.js'></script>
  <script charset="utf-8" src='https://cdn.datatables.net/2.0.0/js/dataTables.bootstrap5.js'></script>
  <script charset="utf-8" src='https://cdn.datatables.net/searchbuilder/1.7.0/js/dataTables.searchBuilder.js'></script>
  <script charset="utf-8" src='https://cdn.datatables.net/searchbuilder/1.7.0/js/searchBuilder.bootstrap5.js'></script>
  <script charset="utf-8" src='https://cdn.datatables.net/datetime/1.5.2/js/dataTables.dateTime.min.js'></script>
  <script charset="utf-8" src='https://cdn.datatables.net/buttons/3.0.0/js/buttons.bootstrap5.js'></script>
  <script charset="utf-8" src='https://cdn.datatables.net/buttons/3.0.0/js/buttons.colVis.min.js'></script>
  
  <!-- Export Table JS -->
  <script charset="utf-8" src='https://cdn.datatables.net/buttons/3.0.0/js/dataTables.buttons.js'></script>
  <script charset="utf-8" src='https://cdn.datatables.net/buttons/3.0.0/js/buttons.dataTables.js'></script>
  <script charset="utf-8" src='https://cdnjs.cloudflare.com/ajax/libs/jszip/3.10.1/jszip.min.js'></script>
  <script charset="utf-8" src='https://cdnjs.cloudflare.com/ajax/libs/pdfmake/0.2.7/pdfmake.min.js'></script>
  <script charset="utf-8" src='https://cdnjs.cloudflare.com/ajax/libs/pdfmake/0.2.7/vfs_fonts.js'></script>
  <script charset="utf-8" src='https://cdn.datatables.net/buttons/3.0.0/js/buttons.html5.min.js'></script>
  <script charset="utf-8" src='https://cdn.datatables.net/buttons/3.0.0/js/buttons.print.min.js'></script>

<script>
    new DataTable('#vm', {
      layout: {
        top1: 'searchBuilder',
        top1Start: {
          buttons: [
            {
              extend: 'copy',
              text: 'Copiar',
              className: 'btn btn-secondary',
              exportOptions: {
                modifier: {
                  page: 'current'
                }
              }
            },
            { extend: 'pdf', text: 'PDF', className: 'btn btn-secondary' },
            { extend: 'excel', text: 'Excel', className: 'btn btn-secondary' },
            { extend: 'print', text: 'imprimir', className: 'btn btn-secondary' }
          ],
        },
        topEnd: {
          search: {
            placeholder: 'Digite a busca aqui'
          }
        },
        bottomEnd: {
          paging: {
            numbers: 5
          }
        }
      },
      columnDefs: [{ className: 'text-center', targets: [1,2,3,6]}],
      scrollX: true,
      language: {
        searchBuilder: {
          add: '+',
          button: 'Filtro',
          data: 'Coluna',
          condition: 'Comparador',
          clearAll: 'Limpar Tudo',
          search: 'Buscar',
          conditions: {
            "date": {
              "after": "Depois",
              "before": "Antes",
              "between": "Entre",
              "empty": "Vazio",
              "equals": "Igual",
              "not": "Não",
              "notBetween": "Não Entre",
              "notEmpty": "Não Vazio"
            },
            "number": {
              "between": "Entre",
              "empty": "Vazio",
              "equals": "Igual",
              "gt": "Maior Que",
              "gte": "Maior ou Igual a",
              "lt": "Menor Que",
              "lte": "Menor ou Igual a",
              "not": "Não",
              "notBetween": "Não Entre",
              "notEmpty": "Não Vazio"
            },
            "string": {
              "contains": "Contém",
              "empty": "Vazio",
              "endsWith": "Termina Com",
              "equals": "Igual",
              "not": "Não",
              "notEmpty": "Não Vazio",
              "startsWith": "Começa Com",
              "notContains": "Não contém",
              "notStartsWith": "Não começa com",
              "notEndsWith": "Não termina com"
            },
            "array": {
              "contains": "Contém",
              "empty": "Vazio",
              "equals": "Igual à",
              "not": "Não",
              "notEmpty": "Não vazio",
              "without": "Não possui"
            }
          },
          logicAnd: 'E',
          logicOr: 'OU',
          value: 'Valor',
          title: {
            0: 'Filtros',
            _: 'Filtros (%d)'
          },
        },
        buttons: {
          copyTitle: 'Dados copiados',
          copyKeys:
            'Appuyez sur <i>ctrl</i> ou <i>\u2318</i> + <i>C</i> pour copier les données du tableau à votre presse-papiers. <br><br>Pour annuler, cliquez sur ce message ou appuyez sur Echap.',
          copySuccess: {
            _: '%d linhas copiadas',
            1: '1 linha copiada'
          }
        },
        'search': "Buscar",
        'emptyTable': "Nenhum registro encontrado",
        'info': "Mostrando de _START_ até _END_ de _TOTAL_ registros",
        //customize pagination prev and next buttons: use arrows instead of words
        'paginate': {
          'previous': '<span class="fa fa-chevron-left"></span>',
          'next': '<span class="fa fa-chevron-right"></span>'
        },
        'lengthMenu': 'Mostrar <select name="example_length" aria-controls="example" class="form-select form-select-sm" id="dt-length-0">' +
          '<option value="5">5</option>' +
          '<option value="10">10</option>' +
          '<option value="20">20</option>' +
          '<option value="40">40</option>' +
          '<option value="50">50</option>' +
          '<option value="-1">All</option>' +
          '</select> linhas'
      }

    });

  </script>

  <!-- hosts -->

<script>
  new DataTable('#hosts', {
    layout: {
      top1: 'searchBuilder',
      top1Start: {
        buttons: [
          {
            extend: 'copy',
            text: 'Copiar',
            className: 'btn btn-secondary',
            exportOptions: {
              modifier: {
                page: 'current'
              }
            }
          },
          { extend: 'pdf', text: 'PDF', className: 'btn btn-secondary' },
          { extend: 'excel', text: 'Excel', className: 'btn btn-secondary' },
          { extend: 'print', text: 'imprimir', className: 'btn btn-secondary' }
        ],
      },
      topEnd: {
        search: {
          placeholder: 'Digite a busca aqui'
        }
      },
      bottomEnd: {
        paging: {
          numbers: 5
        }
      }
    },
    columnDefs: [{ className: 'text-center', targets: [1,2,3,6]}],
    scrollX: true,
    language: {
      searchBuilder: {
        add: '+',
        button: 'Filtro',
        data: 'Coluna',
        condition: 'Comparador',
        clearAll: 'Limpar Tudo',
        search: 'Buscar',
        conditions: {
          "date": {
            "after": "Depois",
            "before": "Antes",
            "between": "Entre",
            "empty": "Vazio",
            "equals": "Igual",
            "not": "Não",
            "notBetween": "Não Entre",
            "notEmpty": "Não Vazio"
          },
          "number": {
            "between": "Entre",
            "empty": "Vazio",
            "equals": "Igual",
            "gt": "Maior Que",
            "gte": "Maior ou Igual a",
            "lt": "Menor Que",
            "lte": "Menor ou Igual a",
            "not": "Não",
            "notBetween": "Não Entre",
            "notEmpty": "Não Vazio"
          },
          "string": {
            "contains": "Contém",
            "empty": "Vazio",
            "endsWith": "Termina Com",
            "equals": "Igual",
            "not": "Não",
            "notEmpty": "Não Vazio",
            "startsWith": "Começa Com",
            "notContains": "Não contém",
            "notStartsWith": "Não começa com",
            "notEndsWith": "Não termina com"
          },
          "array": {
            "contains": "Contém",
            "empty": "Vazio",
            "equals": "Igual à",
            "not": "Não",
            "notEmpty": "Não vazio",
            "without": "Não possui"
          }
        },
        logicAnd: 'E',
        logicOr: 'OU',
        value: 'Valor',
        title: {
          0: 'Filtros',
          _: 'Filtros (%d)'
        },
      },
      buttons: {
        copyTitle: 'Dados copiados',
        copyKeys:
          'Appuyez sur <i>ctrl</i> ou <i>\u2318</i> + <i>C</i> pour copier les données du tableau à votre presse-papiers. <br><br>Pour annuler, cliquez sur ce message ou appuyez sur Echap.',
        copySuccess: {
          _: '%d linhas copiadas',
          1: '1 linha copiada'
        }
      },
      'search': "Buscar",
      'emptyTable': "Nenhum registro encontrado",
      'info': "Mostrando de _START_ até _END_ de _TOTAL_ registros",
      //customize pagination prev and next buttons: use arrows instead of words
      'paginate': {
        'previous': '<span class="fa fa-chevron-left"></span>',
        'next': '<span class="fa fa-chevron-right"></span>'
      },
      'lengthMenu': 'Mostrar <select name="example_length" aria-controls="example" class="form-select form-select-sm" id="dt-length-0">' +
        '<option value="5">5</option>' +
        '<option value="10">10</option>' +
        '<option value="20">20</option>' +
        '<option value="40">40</option>' +
        '<option value="50">50</option>' +
        '<option value="-1">All</option>' +
        '</select> linhas'
    }

  });

</script>

  <!-- vms -->

<script>
  new DataTable('#vms', {
    layout: {
      top1: 'searchBuilder',
      top1Start: {
        buttons: [
          {
            extend: 'copy',
            text: 'Copiar',
            className: 'btn btn-secondary',
            exportOptions: {
              modifier: {
                page: 'current'
              }
            }
          },
          { extend: 'pdf', text: 'PDF', className: 'btn btn-secondary' },
          { extend: 'excel', text: 'Excel', className: 'btn btn-secondary' },
          { extend: 'print', text: 'imprimir', className: 'btn btn-secondary' }
        ],
      },
      topEnd: {
        search: {
          placeholder: 'Digite a busca aqui'
        }
      },
      bottomEnd: {
        paging: {
          numbers: 5
        }
      }
    },
    columnDefs: [{ className: 'text-center', targets: [1,2,3,6]}],
    scrollX: true,
    language: {
      searchBuilder: {
        add: '+',
        button: 'Filtro',
        data: 'Coluna',
        condition: 'Comparador',
        clearAll: 'Limpar Tudo',
        search: 'Buscar',
        conditions: {
          "date": {
            "after": "Depois",
            "before": "Antes",
            "between": "Entre",
            "empty": "Vazio",
            "equals": "Igual",
            "not": "Não",
            "notBetween": "Não Entre",
            "notEmpty": "Não Vazio"
          },
          "number": {
            "between": "Entre",
            "empty": "Vazio",
            "equals": "Igual",
            "gt": "Maior Que",
            "gte": "Maior ou Igual a",
            "lt": "Menor Que",
            "lte": "Menor ou Igual a",
            "not": "Não",
            "notBetween": "Não Entre",
            "notEmpty": "Não Vazio"
          },
          "string": {
            "contains": "Contém",
            "empty": "Vazio",
            "endsWith": "Termina Com",
            "equals": "Igual",
            "not": "Não",
            "notEmpty": "Não Vazio",
            "startsWith": "Começa Com",
            "notContains": "Não contém",
            "notStartsWith": "Não começa com",
            "notEndsWith": "Não termina com"
          },
          "array": {
            "contains": "Contém",
            "empty": "Vazio",
            "equals": "Igual à",
            "not": "Não",
            "notEmpty": "Não vazio",
            "without": "Não possui"
          }
        },
        logicAnd: 'E',
        logicOr: 'OU',
        value: 'Valor',
        title: {
          0: 'Filtros',
          _: 'Filtros (%d)'
        },
      },
      buttons: {
        copyTitle: 'Dados copiados',
        copyKeys:
          'Appuyez sur <i>ctrl</i> ou <i>\u2318</i> + <i>C</i> pour copier les données du tableau à votre presse-papiers. <br><br>Pour annuler, cliquez sur ce message ou appuyez sur Echap.',
        copySuccess: {
          _: '%d linhas copiadas',
          1: '1 linha copiada'
        }
      },
      'search': "Buscar",
      'emptyTable': "Nenhum registro encontrado",
      'info': "Mostrando de _START_ até _END_ de _TOTAL_ registros",
      //customize pagination prev and next buttons: use arrows instead of words
      'paginate': {
        'previous': '<span class="fa fa-chevron-left"></span>',
        'next': '<span class="fa fa-chevron-right"></span>'
      },
      'lengthMenu': 'Mostrar <select name="example_length" aria-controls="example" class="form-select form-select-sm" id="dt-length-0">' +
        '<option value="5">5</option>' +
        '<option value="10">10</option>' +
        '<option value="20">20</option>' +
        '<option value="40">40</option>' +
        '<option value="50">50</option>' +
        '<option value="-1">All</option>' +
        '</select> linhas'
    }

  });

</script>  
</body>

</html>


"@

# Verificar se o caminho existe e criar se necessário
$reportPath = "C:\storages\virtualizacao.html"
if (-not (Test-Path "C:\storages")) {
    New-Item -ItemType Directory -Path "C:\storages\vms.html"
}

# Salvar o HTML gerado no arquivo
$htmlContent | Out-File -FilePath $reportPath -Encoding UTF8

Write-Host "Relatório HTML gerado em: $reportPath" -ForegroundColor Green

# Finalizar log da execução
Stop-Transcript