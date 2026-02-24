{ config, lib, pkgs, ... }:
let
  cfg = config.services.restic-backup-runner;

  configFile = pkgs.writeText "restic-backup-runner-config.json" (builtins.toJSON {
    resticPasswordFile = cfg.settings.resticPasswordFile;
    backupRepo = cfg.settings.backupRepo;
    dbStagingDump = cfg.settings.dbStagingDump;
    dailyBackupsToKeep = cfg.settings.dailyBackupsToKeep;
    sqliteDatabases = cfg.settings.sqliteDatabases;
    postgresDatabases = map sanitizePostgres cfg.settings.postgresDatabases;
    files = cfg.settings.files;
    emailRecipient = cfg.settings.emailRecipient;
    msmtpAccount = cfg.settings.msmtpAccount;
    pingEndpoint = cfg.settings.pingEndpoint;
    pingServiceName = cfg.settings.pingServiceName;
  });

  serviceEnv = lib.mkMerge [
    { RESTIC_BACKUP_CONFIG = configFile; }
    (lib.mkIf (cfg.settings.postgresPasswordsFile != null) {
      POSTGRES_PASSWORDS_FILE = cfg.settings.postgresPasswordsFile;
    })
  ];

  sqliteDbSubmodule = lib.types.submodule ({ ... }: {
    options = {
      name = lib.mkOption {
        type = lib.types.str;
        description = "Logical name for the SQLite backup file.";
      };
      path = lib.mkOption {
        type = lib.types.str;
        description = "Path to the SQLite database file.";
      };
    };
  });

  postgresDbSubmodule = lib.types.submodule ({ ... }: {
    options = {
      name = lib.mkOption {
        type = lib.types.str;
        description = "Logical name for the Postgres dump file.";
      };
      database = lib.mkOption {
        type = lib.types.str;
        description = "Postgres database name.";
      };
      username = lib.mkOption {
        type = lib.types.str;
        description = "Postgres username for pg_dump.";
      };
      host = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Postgres host (defaults to localhost).";
      };
      port = lib.mkOption {
        type = lib.types.nullOr lib.types.port;
        default = null;
        description = "Postgres port (defaults to 5432).";
      };
    };
  });

  sanitizePostgres = db:
    db
    // (lib.optionalAttrs (db.host == null) { host = "localhost"; })
    // (lib.optionalAttrs (db.port == null) { port = 5432; });

in
{
  options.services.restic-backup-runner = {
    enable = lib.mkEnableOption "Restic backup runner";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.restic-backup-runner;
      description = "Package providing the restic-backup-runner script.";
    };

    settings = {
      resticPasswordFile = lib.mkOption {
        type = lib.types.str;
        description = "Path to the restic password file.";
      };

      backupRepo = lib.mkOption {
        type = lib.types.str;
        description = "Path to the restic repository.";
      };

      dbStagingDump = lib.mkOption {
        type = lib.types.str;
        default = "/var/backup/db_dump";
        description = "Staging directory for database dumps.";
      };

      dailyBackupsToKeep = lib.mkOption {
        type = lib.types.int;
        default = 3;
        description = "Number of daily restic snapshots to keep.";
      };

      sqliteDatabases = lib.mkOption {
        type = lib.types.listOf sqliteDbSubmodule;
        default = [];
        description = "SQLite databases to dump before backup.";
      };

      postgresDatabases = lib.mkOption {
        type = lib.types.listOf postgresDbSubmodule;
        default = [];
        description = "Postgres databases to dump before backup.";
      };

      files = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Additional files or directories to back up with restic.";
      };

      postgresPasswordsFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Path to a JSON file mapping database name to password for pg_dump.";
      };

      emailRecipient = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Email recipient for error notifications (optional).";
      };

      msmtpAccount = lib.mkOption {
        type = lib.types.str;
        default = "default";
        description = "msmtp account to use for notifications.";
      };

      pingEndpoint = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "HTTP endpoint to call after a successful backup.";
      };

      pingServiceName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Service name to send to the ping endpoint.";
      };
    };

    timer = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to enable the systemd timer.";
      };

      onCalendar = lib.mkOption {
        type = lib.types.str;
        default = "daily";
        description = "systemd OnCalendar value for scheduled backups.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.settings.pingEndpoint == null || cfg.settings.pingServiceName != null;
        message = "services.restic-backup-runner.settings.pingServiceName must be set when pingEndpoint is set.";
      }
    ];

    systemd.services.restic-backup-runner = {
      description = "Restic backup runner";
      wantedBy = lib.mkIf (!cfg.timer.enable) [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        Group = "root";
        ExecStart = "${cfg.package}/bin/restic-backup-runner";
        Environment = lib.mapAttrsToList (name: value: "${name}=${toString value}") serviceEnv;
      };
    };

    systemd.timers.restic-backup-runner = lib.mkIf cfg.timer.enable {
      description = "Restic backup runner (timer)";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.timer.onCalendar;
        Persistent = true;
      };
    };
  };
}
