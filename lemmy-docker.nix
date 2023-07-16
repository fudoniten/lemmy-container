{ config, lib, pkgs, ... }@toplevel:

with lib;
let
  cfg = config.services.lemmyDocker;

  hostSecrets = config.fudo.secrets.host-secrets."${config.instance.hostname}";

  makeEnvFile = envVars:
    let envLines = mapAttrsToList (var: val: ''${val}="${val}"'') envVars;
    in pkgs.writeText "envFile" (concatStringsSep "\n" envLines);

  makeLemmyImage = { port, stateDirectory, proxyCfg, lemmyCfg, lemmyUiCfg
    , pictrsCfg, postgresCfg, ... }:
    { pkgs, ... }: {
      project.name = "lemmy";
      services = {
        proxy = {
          service = {
            image = proxyCfg.image;
            ports = [ "${port}:8536" ];
            volumes = [ "${proxyCfg.configFile}:/etc/nginx/nginx.conf:ro,Z" ];
            depends_on = [ "pictrs" "lemmy-ui" ];
          };
        };
        lemmy = {
          service = {
            image = lemmyCfg.image;
            hostname = "lemmy";
            env_file = lemmyCfg.envFiles;
            volumes = [ "${lemmyCfg.configFile}:/config/config.hjson:ro,Z" ];
            depends_on = [ "postgres" "pictrs" ];
          };
        };
        lemmy-ui = {
          service = {
            image = lemmyUiCfg.image;
            hostname = "lemmy-ui";
            depends_on = [ "lemmy" ];
          };
        };
        pictrs = {
          service = {
            image = pictrsCfg.image;
            hostname = "pictrs";
            volumes = [ "${stateDirectory}/pictrs:/mnt:Z" ];
            service.user = "991:991";
            env_file = pictrsCfg.envFiles;
          };
        };
        postgres = {
          service = {
            image = postgresCfg.image;
            hostname = "postgres";
            volumes = [
              "${stateDirectory}/postgres:/var/lib/postgresql/data:Z"
              "${postgresCfg.configFile}:/etc/postgresql.conf"
            ];
            env_file = postgresCfg.envFiles;
          };
        };
      };
    };

  nginxCfgFile = pkgs.writeText "lemmy-nginx.conf" ''
    worker_processes auto;

    events {
      worker_connections 1024;
    }

    http {
      map "$request_method:$http_accept" $proxpass {
        default "http://lemmy-ui";
        "~^(?:GET|HEAD):.*?application\/(?:activity|ld)\+json" "http://lemmy";
        "~^(?!(GET|HEAD)).*:" "http://lemmy";
      }

      upstream lemmy {
        server "lemmy:8536";
      }

      upstream lemmy-ui {
        server "lemmy-ui:1234";
      }

      server {
        listen 1236;
        listen 8536;

        server_name localhost;
        server_tokens off;

        gzip on;
        gzip_types text/css application/javascript image/svg+xml;
        gzip_vary on;

        client_max_body_size 20M;

        add_header X-Frame-Options SAMEORIGIN;
        add_header X-Content-Type-Options nosniff;
        add_header X-XSS-Protection "1; mode=block";

        location / {
          proxy_pass $proxpass;

          rewrite ^(.+)/+$ $1 permanent;

          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header Host $host;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        }

        location ~ ^/(api|pictrs|feeds|nodeinfo|.well-known) {
          proxy_pass "http://lemmy";

          proxy_http_version 1.1;
          proxy_set_header Upgrade $http_upgrade;
          proxy_set_header Connection "upgrade";

          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header Host $host;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        }
      }
    }
  '';

  makeLemmyCfg = { hostname, postgresPasswd, pictrsApiKey, smtpServer, ... }:
    pkgs.writeText "lemmy.hjson" (builtins.toJSON {
      database = {
        host = "postgres";
        password = postgresPasswd;
      };
      hostname = hostname;
      pictrs = {
        url = "http://pictrs:8080/";
        api_key = pictrsApiKey;
      };
      email = {
        smtp_server = smtpServer;
        tls_type = "none";
        smtp_from_address = "noreply@${hostname}";
      };
    });

  postgresCfgFile = pkgs.writeText "lemmy-postgres.conf" ''
    # DB Version: 15
    # OS Type: linux
    # DB Type: web
    # Total Memory (RAM): 8 GB
    # CPUs num: 4
    # Data Storage: ssd

    max_connections = 200
    shared_buffers = 2GB
    effective_cache_size = 6GB
    maintenance_work_mem = 512MB
    checkpoint_completion_target = 0.9
    checkpoint_timeout = 86400
    wal_buffers = 16MB
    default_statistics_target = 100
    random_page_cost = 1.1
    effective_io_concurrency = 200
    work_mem = 5242kB
    min_wal_size = 1GB
    max_wal_size = 30GB
    max_worker_processes = 4
    max_parallel_workers_per_gather = 2
    max_parallel_workers = 4
    max_parallel_maintenance_workers = 2

    # Other custom params
    temp_file_size=1GB
    synchronous_commit=off
    # This one shouldn't be on regularly, because DB migrations often take a long time
    # statement_timeout = 10000
  '';

  lemmyDockerComposeCfg = { hostname, port, lemmyCfgFile, nginxCfgFile
    , pictrsApiKey, stateDirectory, postgresPasswd, lemmyDockerImage
    , lemmyUiDockerImage, pictrsDockerImage, postgresCfg, postgresDockerImage
    , ... }:
    let
      defaultLogging = {
        driver = "json-file";
        options = {
          max-size = "50m";
          max-file = "4";
        };
      };
    in pkgs.writeTextDir "docker-compose.yml" (builtins.toJSON {
      version = "3.7";

      services = {
        proxy = {
          image = "nginx:1-alpine";
          ports = [ "${toString port}:8536" ];
          volumes = [ "${nginxCfgFile}:/etc/nginx/nginx.conf:ro,Z" ];
          restart = "always";
          logging = defaultLogging;
        };

        lemmy = {
          image = lemmyDockerImage;
          hostname = "lemmy";
          restart = "always";
          logging = defaultLogging;
          volumes = [ "${lemmyCfgFile}:/config/config.hjson:Z" ];
          depends_on = [ "postgres" "pictrs" ];
        };

        lemmy-ui = {
          image = lemmyUiDockerImage;
          restart = "always";
          logging = defaultLogging;
          depends_on = [ "lemmy" ];
        };

        pictrs = {
          image = pictrsDockerImage;
          hostname = "pictrs";
          restart = "always";
          logging = defaultLogging;
          user = "991:991";
          volumes = [ "${stateDirectory}/pictrs:/mnt:Z" ];
          deploy.resources.limits.memory = "690m";
        };

        postgres = {
          image = postgresDockerImage;
          hostname = "postgres";
          restart = "always";
          logging = defaultLogging;
          volumes = [
            "${stateDirectory}/database:/var/lib/postgresql/data:Z"
            "${postgresCfg}:/etc/postgresql.conf"
          ];
        };
      };
    });

in {
  options.services.lemmyDocker = with types; {
    enable = mkEnableOption "Enable Lemmy running in a Docker container.";

    hostname = mkOption {
      type = str;
      description = "Hostname at which this server is accessible.";
    };

    port = mkOption {
      type = port;
      description = "Port on which to listen for Lemmy connections.";
      default = 8536;
    };

    version = mkOption {
      type = str;
      description = "Lemmy version.";
    };

    state-directory = mkOption {
      type = str;
      description = "Directory at which to store application state.";
    };

    smtp-server = mkOption {
      type = str;
      description = "SMTP server to use for outgoing messages.";
    };

    docker-images = {
      lemmy = mkOption {
        type = str;
        description = "Docker image to use for Lemmy.";
        default =
          "dessalines/lemmy:${toplevel.config.services.lemmyDocker.version}";
      };

      lemmy-ui = mkOption {
        type = str;
        description = "Docker image to use for Lemmy UI.";
        default =
          "dessalines/lemmy-ui:${toplevel.config.services.lemmyDocker.version}";
      };

      pictrs = mkOption {
        type = str;
        description = "Docker image to use for PictRS.";
      };

      postgres = mkOption {
        type = str;
        description = "Docker image to use for Postgres.";
      };
    };
  };

  config = mkIf cfg.enable (let
    postgresPasswd =
      readFile (pkgs.lib.passwd.random-passwd-file "lemmy-postgres-passwd" 30);
    pictrsApiKey =
      readFile (pkgs.lib.passwd.random-passwd-file "lemmy-pictrs-api-key" 30);
  in {
    fudo.secrets.host-secrets."${config.instance.hostname}" = {
      lemmyPictrsEnv = {
        source-file = makeEnvFile {
          PICTRS_OPENTELEMETRY_URL = "http://otel:4137";
          PICTRS__MEDIA__VIDEO_CODEC = "vp9";
          PICTRS__MEDIA__GIF__MAX_WIDTH = "256";
          PICTRS__MEDIA__GIF__MAX_HEIGHT = "256";
          PICTRS__MEDIA__GIF__MAX_AREA = "65536";
          PICTRS__MEDIA__GIF__MAX_FRAME_COUNT = "400";
          RUST_LOG = "debug";
          PICTRS__API_KEY = pictrsApiKey;
        };
        target-file = "/run/lemmy/pictrs.env";
      };
      lemmyPostgresEnv = {
        source-file = makeEnvFile {
          POSTGRES_USER = "lemmy";
          POSTGRES_PASSWORD = postgresPasswd;
          POSTGRES_DB = "lemmy";
        };
        target-file = "/run/lemmy/postgres.env";
      };
    };

    virtualisation = {
      arion = {
        backend = "podman-socket";
        projects.lemmy.settings = let
          lemmyImage = makeLemmyImage {
            port = cfg.port;
            stateDirectory = cfg.state-directory;
            proxyCfg = {
              image = "nginx:1-alpine";
              configFile = nginxCfgFile;
            };
            lemmyCfg = {
              image = cfg.docker-images.lemmy;
              configFile = makeLemmyCfg {
                inherit (cfg) hostname;
                inherit postgresPasswd pictrsApiKey;
                smtpServer = cfg.smtp-server;
              };
              envFiles = [ (makeEnvFile { RUST_LOG = "warn"; }) ];
            };
            lemmyUiCfg = {
              image = cfg.docker-images.lemmy-ui;
              envFiles = [
                (mkEnvFile {
                  LEMMY_UI_LEMMY_INTERNAL_HOST = "lemmy:8536";
                  LEMMY_UI_LEMMY_EXTERNAL_HOST = cfg.hostname;
                  LEMMY_UI_HTTPS = true;
                })
              ];
            };
            pictrsCfg = {
              image = cfg.docker-images.pictrs;
              envFiles = [ host-secrets.lemmy-pictrs-env-file.target-file ];
            };
            postgresCfg = {
              image = cfg.docker-images.postgres;
              envFiles = [ hostSecrets.lemmy-postgres-env-file.target-file ];
              configFile = postgresCfgFile;
            };
          };
        in { imports = [ lemmyImage ]; };
      };
    };

    services.nginx = {
      enable = true;
      virtualHosts."${cfg.hostname}" = {
        enableACME = true;
        forceSSL = true;
        locations = {
          "/" = {
            proxyPass = "http://localhost:${toString cfg.port}";
            proxyWebsockets = true;
            extraConfig = ''
              proxy_set_header Host $host;
              proxy_set_header Upgrade $http_upgrade;
              proxy_set_header Connection "Upgrade";
              proxy_set_header X-Real-IP $remote_addr;
              proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            '';
          };
        };
      };
    };
  });
}
