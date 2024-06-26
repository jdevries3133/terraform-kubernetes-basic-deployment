resource "kubernetes_namespace" "app" {
  metadata {
    name = var.app_name
  }
}

resource "kubernetes_config_map" "app_config" {
  metadata {
    name      = "${var.app_name}-config"
    namespace = kubernetes_namespace.app.metadata.0.name
  }

  data = merge({
    POSTGRES_DB   = var.app_name
    POSTGRES_HOST = "${helm_release.db.name}-postgresql.${kubernetes_namespace.app.metadata.0.name}.svc.cluster.local"
    POSTGRES_USER = var.app_name
  }, var.extra_env)
}

resource "kubernetes_secret" "app_secrets" {
  metadata {
    name      = "${var.app_name}-secrets"
    namespace = kubernetes_namespace.app.metadata.0.name
  }
  data = {
    POSTGRES_PASSWORD = random_password.db_password.result
    DATABASE_URL = join("", [
      "postgresql://",
      var.app_name,
      ":", random_password.db_password.result,
      "@",
      "${helm_release.db.name}-postgresql.${kubernetes_namespace.app.metadata.0.name}.svc.cluster.local:5432",
      "/", var.app_name
    ])
  }
}

resource "kubernetes_deployment" "app" {
  metadata {
    name      = "${var.app_name}-deployment"
    namespace = kubernetes_namespace.app.metadata.0.name
  }

  spec {
    replicas = var.replica_count

    selector {
      match_labels = {
        app = var.app_name
      }
    }

    template {
      metadata {
        labels = {
          app = var.app_name
        }
      }
      spec {
        container {
          name  = var.app_name
          image = var.container
          env_from {
            config_map_ref {
              name = kubernetes_config_map.app_config.metadata.0.name
            }
          }
          env_from {
            secret_ref {
              name = kubernetes_secret.app_secrets.metadata.0.name
            }
          }
          startup_probe {
            http_get {
              path = var.startup_probe_path
              port = var.application_port
            }
          }
        }
      }
    }
  }
}


resource "kubernetes_service" "app" {
  metadata {
    name      = "${var.app_name}-service"
    namespace = kubernetes_namespace.app.metadata.0.name
  }

  wait_for_load_balancer = false
  spec {
    selector = {
      app = var.app_name
    }
    session_affinity = "ClientIP"
    port {
      port        = 8000
      target_port = var.application_port
    }
  }
}

resource "kubernetes_ingress_v1" "app" {
  metadata {
    name      = "${var.app_name}-ingress"
    namespace = kubernetes_namespace.app.metadata[0].name
    annotations = {
      "cert-manager.io/cluster-issuer" = "letsencrypt-prod"
      "acme.cert-manager.io/http01-edit-in-place" =  "true"
      "cert-manager.io/issue-temporary-certificate" = "true"
    }
  }

  spec {
    ingress_class_name = "nginx"

    tls {
      hosts = [var.domain]
      secret_name = "${var.app_name}-tls-certificate"
    }

    rule {
      host = var.domain
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.app.metadata.0.name
              port {
                number = 8000
              }
            }
          }
        }
      }
    }
  }
}


/******************************************************************************
 * Postgresql DB
 */

resource "random_password" "db_password" {
  length  = 48
  special = false
}

resource "helm_release" "db" {
  name       = "db"
  namespace  = kubernetes_namespace.app.metadata.0.name
  repository = "https://charts.bitnami.com/bitnami"
  chart      = "postgresql"
  version    = "12.7.1"

  values = [file("${path.module}/psql_values.yml")]

  set {
    name  = "global.postgresql.auth.database"
    value = var.app_name
  }
  set {
    name  = "global.postgresql.auth.username"
    value = var.app_name
  }
  set {
    name  = "primary.persistence.size"
    value = var.storage_size
  }
  set_sensitive {
    name  = "global.postgresql.auth.password"
    value = random_password.db_password.result
  }
}
