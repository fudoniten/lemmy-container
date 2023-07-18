{ config, lib, pkgs, ... }@toplevel:

with lib;
let
  cfg = config.services.lemmyDocker;

  hostSecrets = config.fudo.secrets.host-secrets."${config.instance.hostname}";

  makeEnvFile = envVars:
    let envLines = mapAttrsToList (var: val: ''${var}="${val}"'') envVars;
    in pkgs.writeText "envFile" (concatStringsSep "\n" envLines);

  makeLemmyImage = { port, stateDirectory, proxyCfg, lemmyCfg, lemmyUiCfg
    , pictrsCfg, postgresCfg, ... }:
    { pkgs, ... }: {
      project.name = "lemmy";
      services = {
        proxy = {
          service = {
            image = proxyCfg.image;
            ports = [ "${toString port}:8536" ];
            volumes = [ "${proxyCfg.configFile}:/etc/nginx/nginx.conf:ro,Z" ];
            depends_on = [ "lemmy" "lemmy-ui" "pictrs" ];
            restart = "always";
          };
        };
        lemmy = {
          service = {
            image = lemmyCfg.image;
            hostname = "lemmy";
            env_file = [ lemmyCfg.envFile ];
            volumes = [ "${lemmyCfg.configFile}:/config/config.hjson:ro,Z" ];
            depends_on = [ "postgres" "pictrs" ];
            restart = "always";
          };
        };
        lemmy-ui = {
          service = {
            image = lemmyUiCfg.image;
            hostname = "lemmy-ui";
            depends_on = [ "lemmy" ];
            restart = "always";
          };
        };
        pictrs = {
          service = {
            image = pictrsCfg.image;
            hostname = "pictrs";
            volumes = [ "${stateDirectory}/pictrs:/mnt:Z" ];
            user = "${toString pictrsCfg.uid}:${toString pictrsCfg.uid}";
            env_file = [ pictrsCfg.envFile ];
            restart = "always";
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
            user = "${toString postgresCfg.uid}:${toString postgresCfg.uid}";
            env_file = [ postgresCfg.envFile ];
            restart = "always";
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
      error_log stderr info;
      access_log stdout;

      map "$request_method:$http_accept" $proxpass {
        # If no explicit matches exists below, send traffic to lemmy-ui
        default "http://lemmy-ui";

        # GET/HEAD requests that accepts ActivityPub or Linked Data JSON should go to lemmy.
        #
        # These requests are used by Mastodon and other fediverse instances to look up profile information,
        # discover site information and so on.
        "~^(?:GET|HEAD):.*?application\/(?:activity|ld)\+json" "http://lemmy";

        # All non-GET/HEAD requests should go to lemmy
        #
        # Rather than calling out POST, PUT, DELETE, PATCH, CONNECT and all the verbs manually
        # we simply negate the GET|HEAD pattern from above and accept all possibly $http_accept values
        "~^(?!(GET|HEAD)).*:" "http://lemmy";
      }

      upstream lemmy {
        # Must map to lemmy image
        server "lemmy:8536";
      }

      upstream lemmy-ui {
        # Must map to lemmy-ui image
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

        # Send actual client IP upstream
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;

        # frontend general requests
        location / {
            proxy_pass $proxpass;
            rewrite ^(.+)/+$ $1 permanent;
        }

        # security.txt
        location = /.well-known/security.txt {
            proxy_pass "http://lemmy-ui";
        }

        # backend
        location ~ ^/(api|pictrs|feeds|nodeinfo|.well-known) {
            proxy_pass "http://lemmy";

            # proxy common stuff
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
        }
      }
    }
  '';

  makeLemmyCfg = { hostname, postgresPasswd, pictrsApiKey, smtpServer, siteName
    , adminPasswd ? null, ... }:
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
      setup = {
        admin_username = "admin";
        admin_password = adminPasswd;
        site_name = siteName;
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

in {
  options.services.lemmyDocker = with types; {
    enable = mkEnableOption "Enable Lemmy running in a Docker container.";

    hostname = mkOption {
      type = str;
      description = "Hostname at which this server is accessible.";
    };

    site-name = mkOption {
      type = str;
      description = "Name of this server.";
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
    adminPasswd = readFile
      (pkgs.lib.passwd.stablerandom-passwd-file "lemmy-admin-passwd"
        config.instance.build-seed);
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
          RUST_BACKTRACE = "full";
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
      lemmyUiEnv = {
        source-file = makeEnvFile {
          LEMMY_UI_LEMMY_INTERNAL_HOST = "lemmy:8536";
          LEMMY_UI_LEMMY_EXTERNAL_HOST = cfg.hostname;
          LEMMY_UI_HTTPS = false;
        };
        target-file = "/run/lemmy/lemmy-ui.env";
      };
      lemmyCfg = {
        source-file = makeLemmyCfg {
          inherit (cfg) hostname;
          inherit postgresPasswd pictrsApiKey;
          smtpServer = cfg.smtp-server;
          adminPasswd = adminPasswd;
          siteName = cfg.site-name;
        };
        target-file = "/run/lemmy/lemmy.hjson";
      };
      lemmyNginxCfg = {
        source-file = nginxCfgFile;
        target-file = "/run/lemmy/nginx.conf";
      };
      lemmyPostgresCfg = {
        source-file = postgresCfgFile;
        target-file = "/var/lemmy/postgres.conf";
      };
    };

    users.users = {
      lemmy-pictrs = {
        isSystemUser = true;
        uid = 986;
        group = "lemmy-pictrs";
      };
      lemmy-postgres = {
        isSystemUser = true;
        uid = 985;
        group = "lemmy-postgres";
      };
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.state-directory}/pictrs 0700 lemmy-pictrs root - -"
      "d ${cfg.state-directory}/postgres 0700 lemmy-postgres root - -"
    ];

    virtualisation = {
      arion = {
        backend = "podman-socket";
        projects.lemmy.settings = let
          lemmyImage = makeLemmyImage {
            port = cfg.port;
            stateDirectory = cfg.state-directory;
            proxyCfg = {
              image = "nginx:1-alpine";
              configFile = hostSecrets.lemmyNginxCfg.target-file;
            };
            lemmyCfg = {
              image = cfg.docker-images.lemmy;
              configFile = hostSecrets.lemmyCfg.target-file;
              envFile = toString (makeEnvFile {
                RUST_LOG = "warn";
                RUST_BACKTRACE = "full";
              });
            };
            lemmyUiCfg = {
              image = cfg.docker-images.lemmy-ui;
              envFile = hostSecrets.lemmyUiEnv.target-file;
            };
            pictrsCfg = {
              image = cfg.docker-images.pictrs;
              envFile = hostSecrets.lemmyPictrsEnv.target-file;
              uid = config.users.users.lemmy-pictrs.uid;
            };
            postgresCfg = {
              image = cfg.docker-images.postgres;
              envFile = hostSecrets.lemmyPostgresEnv.target-file;
              configFile = hostSecrets.lemmyPostgresCfg.target-file;
              uid = config.users.users.lemmy-postgres.uid;
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
            recommendedProxySettings = true;
            # extraConfig = ''
            #   proxy_set_header Host $host;
            #   proxy_set_header Upgrade $http_upgrade;
            #   proxy_set_header Connection "Upgrade";
            #   proxy_set_header X-Real-IP $remote_addr;
            #   proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            # '';
          };
        };
      };
    };
  });
}
