# Azure Container Apps Environment (required for Container Apps)
# When app_workload_profile is set (e.g. D4), workload profiles are added so the main app can use 16 Gi per replica.
# If the environment was created without workload profiles, adding them forces recreation (destroy + create) of the environment.
resource "azurerm_container_app_environment" "main" {
  name                       = "${replace(replace(var.resource_group_name, "-", ""), "_", "")}-env"
  location                   = azurerm_resource_group.main.location
  resource_group_name        = azurerm_resource_group.main.name
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  dynamic "workload_profile" {
    for_each = var.app_workload_profile != "" ? [1] : []
    content {
      name                  = "Consumption"
      workload_profile_type = "Consumption"
      minimum_count         = 0
      maximum_count         = 10
    }
  }

  dynamic "workload_profile" {
    for_each = var.app_workload_profile != "" ? [1] : []
    content {
      name                  = var.app_workload_profile
      workload_profile_type = var.app_workload_profile
      minimum_count         = 0
      maximum_count         = 3
    }
  }

  tags = var.tags
}

# Log Analytics Workspace (required for Container Apps Environment)
resource "azurerm_log_analytics_workspace" "main" {
  name                = "${replace(replace(var.resource_group_name, "-", ""), "_", "")}-logs"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  
  tags = var.tags
}

# Storage for volume mounts (Azure Files)
resource "azurerm_container_app_environment_storage" "data" {
  name                         = "data"
  container_app_environment_id = azurerm_container_app_environment.main.id
  account_name                 = azurerm_storage_account.main.name
  share_name                   = azurerm_storage_share.data.name
  access_key                   = azurerm_storage_account.main.primary_access_key
  access_mode                  = "ReadWrite"
}

resource "azurerm_container_app_environment_storage" "uploads" {
  name                         = "uploads"
  container_app_environment_id = azurerm_container_app_environment.main.id
  account_name                 = azurerm_storage_account.main.name
  share_name                   = azurerm_storage_share.uploads.name
  access_key                   = azurerm_storage_account.main.primary_access_key
  access_mode                  = "ReadWrite"
}

resource "azurerm_container_app_environment_storage" "databases" {
  name                         = "databases"
  container_app_environment_id = azurerm_container_app_environment.main.id
  account_name                 = azurerm_storage_account.main.name
  share_name                   = azurerm_storage_share.databases.name
  access_key                   = azurerm_storage_account.main.primary_access_key
  access_mode                  = "ReadWrite"
}

resource "azurerm_container_app_environment_storage" "notebooks" {
  name                         = "notebooks"
  container_app_environment_id = azurerm_container_app_environment.main.id
  account_name                 = azurerm_storage_account.main.name
  share_name                   = azurerm_storage_share.notebooks.name
  access_key                   = azurerm_storage_account.main.primary_access_key
  access_mode                  = "ReadWrite"
}

resource "azurerm_container_app_environment_storage" "config" {
  name                         = "config"
  container_app_environment_id = azurerm_container_app_environment.main.id
  account_name                 = azurerm_storage_account.main.name
  share_name                   = azurerm_storage_share.config.name
  access_key                   = azurerm_storage_account.main.primary_access_key
  access_mode                  = "ReadWrite"
}

resource "azurerm_container_app_environment_storage" "kernels" {
  name                         = "kernels"
  container_app_environment_id = azurerm_container_app_environment.main.id
  account_name                 = azurerm_storage_account.main.name
  share_name                   = azurerm_storage_share.kernels.name
  access_key                   = azurerm_storage_account.main.primary_access_key
  access_mode                  = "ReadWrite"
}

# Main Application Container App
resource "azurerm_container_app" "app" {
  name                         = "${replace(replace(var.resource_group_name, "-", ""), "_", "")}-app"
  container_app_environment_id = azurerm_container_app_environment.main.id
  resource_group_name          = azurerm_resource_group.main.name
  revision_mode                = "Single"
  workload_profile_name        = var.app_workload_profile != "" ? var.app_workload_profile : null  # null = Consumption (4 Gi max); D4 = 16 Gi per replica

  registry {
    server   = var.acr_login_server
    username = var.acr_sp_client_id != "" ? var.acr_sp_client_id : var.acr_admin_username
    password_secret_name = "acr-password"
  }

  secret {
    name  = "acr-password"
    value = var.acr_sp_client_id != "" ? var.acr_sp_client_secret : var.acr_admin_password
  }

  # Add secret environment variables as secrets
  dynamic "secret" {
    for_each = var.secret_environment_variables
    content {
      name  = replace(secret.key, "-", "_")
      value = secret.value
    }
  }

  template {
    min_replicas     = 0  # Scale to zero when idle (app + worker scale together)
    max_replicas     = 1
    revision_suffix  = var.app_revision_suffix != "" ? var.app_revision_suffix : null  # Set to force new revision (restart); e.g. "restart-1" or timestamp()

    container {
      name  = "corridor-app"
      image = "${var.acr_login_server}/${var.image_name}:${var.image_version}"
      # Single-app mode: give corridor-app the full Consumption budget minus nginx sidecar.
      cpu    = 1.75
      memory = "3.5Gi"

      env {
        name  = "CORRIDOR_ENV"
        value = var.environment
      }

      # Bind to all interfaces so nginx in the same replica can reach via localhost
      env {
        name  = "CORRIDOR_APP_HOST"
        value = "0.0.0.0"
      }

      env {
        name  = "CORRIDOR_APP_PROCESSES"
        value = "1"
      }

      env {
        name  = "CORRIDOR_KERNEL_WORKER_URL"
        value = "https://${azurerm_container_app.worker.ingress[0].fqdn}"
      }

      env {
        name  = "CORRIDOR_SQLALCHEMY_DATABASE_URI"
        value = var.database_connection_string != "" ? var.database_connection_string : "postgresql://${var.db_admin_username}:${urlencode(var.db_admin_password)}@${azurerm_postgresql_flexible_server.main.fqdn}:5432/${var.db_name}"
      }

      env {
        name  = "CORRIDOR_LICENSE_KEY"
        value = var.corridor_license_key
      }

      env {
        name  = "CORRIDOR_OUTPUT_DATA_LOCATION"
        value = "/opt/corridor/data/results/{}.parquet"
      }

      env {
        name  = "CORRIDOR_SENTRY_CONFIG__environment"
        value = var.client
      }

      env {
        name  = "TMPDIR"
        value = "/tmp"
      }

      # Add secret environment variables
      dynamic "env" {
        for_each = var.secret_environment_variables
        content {
          name        = replace(env.key, "-", "_")
          secret_name = replace(env.key, "-", "_")
        }
      }

      volume_mounts {
        name = "data"
        path = "/opt/corridor/data"
      }

      volume_mounts {
        name = "uploads"
        path = "/opt/corridor/uploads"
      }

      volume_mounts {
        name = "databases"
        path = "/opt/corridor/databases"
      }

      volume_mounts {
        name = "kernels"
        path = "/opt/corridor/kernels"
      }

      volume_mounts {
        name = "config"
        path = "/opt/corridor/config"
      }

      # Allow cold starts to finish before liveness checks.
      startup_probe {
        transport               = "HTTP"
        port                    = 5002
        path                    = "/api"
        interval_seconds        = 30
        timeout                 = 5
        failure_count_threshold = 10
      }

      # Liveness: if app stops responding on 5002, ACA restarts this container
      liveness_probe {
        transport             = "HTTP"
        port                  = 5002
        path                  = "/api"
        initial_delay         = 60
        interval_seconds      = 30
        timeout               = 5
        failure_count_threshold = 3
      }

      # Start the unified API/UI after the migration init container succeeds.
      args = [
        "/bin/bash",
        "-c",
        "cd /opt/corridor && source venv/bin/activate && exec venv/bin/corridor-api run"
      ]
    }
    /*
    # Jupyter container (sidecar)
    container {
      name   = "corridor-jupyter"
      ...
    }
    */
    # Nginx container (sidecar - reverse proxy/routing)
    container {
      name   = "nginx"
      image  = "nginx:1.25-alpine"
      cpu    = 0.25
      memory = "0.5Gi"

      # Nginx proxies to:
      # - / -> localhost:5002 (corridor-app)
      # - /jupyter -> localhost:5003 (corridor-jupyter)
      args = [
        "/bin/sh",
        "-c",
        <<-EOT
        cat > /usr/share/nginx/html/502.html << 'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Application Loading - GenGuardX</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;
            background: #ffffff;
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            color: #1a1a1a;
        }
        .container {
            text-align: center;
            padding: 2rem;
            max-width: 600px;
        }
        .logo {
            margin-bottom: 2rem;
            display: flex;
            align-items: center;
            justify-content: center;
        }
        .logo img {
            height: 40px;
            width: auto;
            max-width: min(100%, 320px);
        }
        .icon {
            font-size: 4rem;
            margin-bottom: 2rem;
            animation: float 3s ease-in-out infinite;
        }
        h1 {
            font-size: 2rem;
            margin-bottom: 1rem;
            font-weight: 600;
            color: #1a1a1a;
        }
        .subtitle {
            font-size: 1rem;
            color: #666;
            margin-bottom: 2rem;
            line-height: 1.6;
        }
        .info {
            font-size: 0.9rem;
            color: #666;
            margin-bottom: 2rem;
            line-height: 1.6;
        }
        .contact {
            font-size: 0.875rem;
            color: #666;
            margin-top: 2rem;
        }
        .contact a {
            color: #0066ff;
            text-decoration: none;
        }
        .contact a:hover {
            text-decoration: underline;
        }
        @keyframes float {
            0%, 100% { transform: translateY(0px); }
            50% { transform: translateY(-10px); }
        }
    </style>
    <script>
        setTimeout(function() {
            location.reload();
        }, 10000);
    </script>
</head>
<body>
    <div class="container">
        <div class="logo">
            <img src="https://ggx.corridorplatforms.com/assets/logo-for-white.svg" alt="GenGuardX" />
        </div>
        <div class="icon">⏳</div>
        <h1>Application is loading up</h1>
        <p class="subtitle">Your application is starting. This typically takes 2-5 minutes.</p>
        <p class="info">This page will automatically refresh every 10 seconds.</p>
        <p class="contact">If the issue persists after 5 minutes, contact support at <a href="mailto:admin@genguardx.ai">admin@genguardx.ai</a></p>
    </div>
</body>
</html>
HTML
        cat > /etc/nginx/nginx.conf << 'NGX'
events { worker_connections 1024; }
http {
  upstream app { server 127.0.0.1:5002; }
  upstream jupyter { server 127.0.0.1:5003; }
  server {
    listen 80;
    client_max_body_size 0;
    proxy_connect_timeout 60s;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
    proxy_request_buffering off;
    error_page 502 503 504 /502.html;
    location = /502.html {
      root /usr/share/nginx/html;
      internal;
    }
    location = /health { default_type text/plain; return 200 'ok'; }
    location /jupyter { proxy_pass http://jupyter; proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr; proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto https; proxy_http_version 1.1; proxy_set_header Upgrade $http_upgrade; proxy_set_header Connection "upgrade"; }
    location / { proxy_pass http://app; proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr; proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto https; }
  }
}
NGX
        exec nginx -g 'daemon off;'
        EOT
      ]
    }

    volume {
      name         = "kernels"
      storage_type = "AzureFile"
      storage_name = azurerm_container_app_environment_storage.kernels.name
      # Image runs as root; kernel environments require owner-only writes and symlinks.
      mount_options = "uid=0,gid=0,dir_mode=0700,file_mode=0700,mfsymlinks"
    }

    volume {
      name         = "data"
      storage_type = "AzureFile"
      storage_name = azurerm_container_app_environment_storage.data.name
    }

    volume {
      name         = "uploads"
      storage_type = "AzureFile"
      storage_name = azurerm_container_app_environment_storage.uploads.name
    }

    volume {
      name         = "databases"
      storage_type = "AzureFile"
      storage_name = azurerm_container_app_environment_storage.databases.name
    }

    volume {
      name         = "config"
      storage_type = "AzureFile"
      storage_name = azurerm_container_app_environment_storage.config.name
    }

    volume {
      name         = "notebooks"
      storage_type = "AzureFile"
      storage_name = azurerm_container_app_environment_storage.notebooks.name
    }
  }

        ingress {
          external_enabled = true
          target_port      = 80  # Nginx listens on port 80
          transport        = "http"
          allow_insecure_connections = false

    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }

  depends_on = [
    azurerm_postgresql_flexible_server_database.main,
    azurerm_postgresql_flexible_server_firewall_rule.allow_azure,
    azurerm_postgresql_flexible_server_configuration.max_locks_per_transaction,
  ]

  tags = var.tags
}

# Worker Container App
resource "azurerm_container_app" "worker" {
  name                         = "${replace(replace(var.resource_group_name, "-", ""), "_", "")}-worker"
  container_app_environment_id = azurerm_container_app_environment.main.id
  resource_group_name          = azurerm_resource_group.main.name
  revision_mode                = "Single"

  registry {
    server               = var.acr_login_server
    username             = var.acr_sp_client_id != "" ? var.acr_sp_client_id : var.acr_admin_username
    password_secret_name = "acr-password"
  }

  secret {
    name  = "acr-password"
    value = var.acr_sp_client_id != "" ? var.acr_sp_client_secret : var.acr_admin_password
  }

  dynamic "secret" {
    for_each = var.secret_environment_variables
    content {
      name  = replace(secret.key, "-", "_")
      value = secret.value
    }
  }

  template {
    min_replicas = 0
    max_replicas = var.worker_max_replicas

    container {
      name   = "corridor-worker"
      image  = "${var.acr_login_server}/${var.image_name}:${var.image_version}"
      cpu    = var.worker_cpu
      memory = "${var.worker_memory}Gi"

      env {
        name  = "CORRIDOR_KERNEL_WORKER_HOST"
        value = "0.0.0.0"
      }

      env {
        name  = "CORRIDOR_ENV"
        value = var.environment
      }

      env {
        name  = "CORRIDOR_API_URL"
        value = "https://${replace(replace(var.resource_group_name, "_", ""), "-", "")}-app.${azurerm_container_app_environment.main.default_domain}/"
      }

      env {
        name  = "CORRIDOR_SQLALCHEMY_DATABASE_URI"
        value = var.database_connection_string != "" ? var.database_connection_string : "postgresql://${var.db_admin_username}:${urlencode(var.db_admin_password)}@${azurerm_postgresql_flexible_server.main.fqdn}:5432/${var.db_name}"
      }

      env {
        name  = "CORRIDOR_LICENSE_KEY"
        value = var.corridor_license_key
      }

      env {
        name  = "CORRIDOR_OUTPUT_DATA_LOCATION"
        value = "/opt/corridor/data/results/{}.parquet"
      }

      env {
        name  = "CORRIDOR_SENTRY_CONFIG__environment"
        value = var.client
      }

      env {
        name  = "TMPDIR"
        value = "/tmp"
      }

      dynamic "env" {
        for_each = var.secret_environment_variables
        content {
          name        = replace(env.key, "-", "_")
          secret_name = replace(env.key, "-", "_")
        }
      }

      volume_mounts {
        name = "data"
        path = "/opt/corridor/data"
      }

      volume_mounts {
        name = "uploads"
        path = "/opt/corridor/uploads"
      }

      volume_mounts {
        name = "kernels"
        path = "/opt/corridor/kernels"
      }

      volume_mounts {
        name = "config"
        path = "/opt/corridor/config"
      }

      volume_mounts {
        name = "databases"
        path = "/opt/corridor/databases"
      }

      readiness_probe {
        transport = "TCP"
        port      = 5001
      }

      args = [
        "/bin/bash",
        "-c",
        "cd /opt/corridor && source venv/bin/activate && exec venv/bin/corridor-worker run"
      ]
    }

    volume {
      name         = "kernels"
      storage_type = "AzureFile"
      storage_name = azurerm_container_app_environment_storage.kernels.name
      # Image runs as root; kernel environments require owner-only writes and symlinks.
      mount_options = "uid=0,gid=0,dir_mode=0700,file_mode=0700,mfsymlinks"
    }

    volume {
      name         = "config"
      storage_type = "AzureFile"
      storage_name = azurerm_container_app_environment_storage.config.name
    }

    volume {
      name         = "databases"
      storage_type = "AzureFile"
      storage_name = azurerm_container_app_environment_storage.databases.name
    }

    volume {
      name         = "data"
      storage_type = "AzureFile"
      storage_name = azurerm_container_app_environment_storage.data.name
    }

    volume {
      name         = "uploads"
      storage_type = "AzureFile"
      storage_name = azurerm_container_app_environment_storage.uploads.name
    }

      }

  # Keep the kernel server private to this Container Apps environment.
  ingress {
    external_enabled           = false
    target_port                = 5001
    transport                  = "http"
    allow_insecure_connections = false

    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }

  tags = var.tags
}
