# restic-backup-runner

Small Nix flake + NixOS module that runs a bash script to back up files and DB dumps with Restic. Built for a single self-hosted server.

## What it does
- Dumps SQLite and Postgres databases to a staging folder
- Backs up those dumps plus any extra files/dirs with Restic
- Optionally pings an endpoint when it finishes

## Use (NixOS)
Import the module and set the basics:

```nix
{
  imports = [
    inputs.restic-backup-runner.nixosModules.default
  ];

  services.restic-backup-runner = {
    enable = true;
    settings = {
      resticPasswordFile = "/secrets/restic/password.txt";
      backupRepo = "/var/backup/restic";
      files = [ "/srv/data" ];
    };
  };
}
```

Notes:
- The restic repo and password file must already exist on the server.
- If you use Postgres, set `postgresPasswordsFile` to a JSON map of db name -> password.
- If you use `pingEndpoint`, set `pingAuthTokenFile` to a readable file containing the bearer token.

That’s it. Keep it boring and it should just run.
