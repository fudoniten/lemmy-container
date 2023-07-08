{ config, lib, pkgs, ... }:

with lib;
let
  cfg = config.services.lemmyDocker;

  hostSecrets = config.fudo.secrets.host-secrets."${config.instance.hostname}";

  lemmyDockerImage = { hostname, lemmyDockerImage, lemmyUiDockerImage
    , nginxCfgFile, pictrsApiKey, pictrsDockerImage, port, postgresDockerImage
    , postgresPasswd, smtpServer, stateDirectory, ... }:
    let
      lemmyCfgFile =
        lemmyCfg { inherit hostname postgresPasswd pictrsApiKey smtpServer; };
      lemmyDockerComposeCfgDir = lemmyDockerComposeCfg {
        inherit hostname port lemmyCfgFile nginxCfgFile pictrsApiKey
          stateDirectory postgresPasswd lemmyDockerImage lemmyUiDockerImage
          pictrsDockerImage postgresDockerImage;
      };
    in pkgs.stdenv.mkDerivation {
      name = "lemmy-docker-image";
      src = lemmyDockerComposeCfgDir;
      buildInputs = with pkgs; [ docker-compose ];
      buildPhase = "docker compose build";
      installPhase = "ls > $out";
    };

  nginxCfg = writeTextFile "lemmy-nginx.conf" ''
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

  lemmyCfg = { hostname, postgresPasswd, pictrsApiKey, smtpServer, ... }: {
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
  };

  lemmyDockerComposeCfg = { hostname, port, lemmyCfgFile, nginxCfgFile
    , pictrsApiKey, stateDirectory, postgresPasswd, lemmyDockerImage
    , lemmyUiDockerImage, pictrsDockerImage, postgresDockerImage, ... }:
    let
      defaultLogging = {
        driver = "json-file";
        options = {
          max-size = "50m";
          max-file = "4";
        };
      };
    in writeTextDir "docker-compose.yml" (toJSON {
      version = "3.7";

      services = {
        proxy = {
          image = "nginx:1-alpine";
          ports = [ "${port}:8536" ];
          volumes = [ "${nginxCfg}:/etc/nginx/nginx.conf:ro,Z" ];
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
      lemmyDockerEnv = {
        source-file = writeTextFile "lemmy-docker-env" ''
          PICTRS__API_KEY=\"${pictrsApiKey}\"
          POSTGRES_PASSWORD=\"${postgresPassword}\"
        '';
        target-file = "/run/lemmy-docker/env";
      };
    };

    virtualisation = {
      oci-containers.containers.lemmy = {
        # Not sure what the image should be...
        image = "lemmy/lemmy";
        environment = {
          LEMMY_UI_LEMMY_INTERNAL_HOST = "lemmy:8536";
          LEMMY_UI_LEMMY_EXTERNAL_HOST = cfg.hostname;
          LEMMY_UI_HTTPS = "false";
          PICTRS_OPENTELEMETRY_URL = "http://otel:4137";
          RUST_LOG = "debug";
          RUST_BACKTRACE = "full";
          PICTRS__MEDIA__VIDEO_CODEC = "vp9";
          PICTRS__MEDIA__GIF__MAX_WIDTH = "256";
          PICTRS__MEDIA__GIF__MAX_HEIGHT = "256";
          PICTRS__MEDIA__GIF__MAX_AREA = "65536";
          PICTRS__MEDIA__GIF__MAX_FRAME_COUNT = "400";
          POSTGRES_USER = "lemmy";
          POSTGRES_DB = "lemmy";
        };
        environmentFiles = [ hostSecrets.lemmyDockerEnv.target-file ];
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
