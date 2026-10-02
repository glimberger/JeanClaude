# Module home-manager qui fait tourner le bot Telegram comme service systemd "utilisateur".
#
# C'est la variante Nix de deploy/jcvd-bot.service : le même service, mais déclaré dans la
# configuration home-manager de la machine au lieu d'être activé à la main avec
# `systemctl --user enable`. Mode d'emploi : docs/DEPLOIEMENT_PI.md, section 12.
#
# home-manager est l'outil qui décrit l'environnement d'un utilisateur (programmes, fichiers
# de configuration, services) dans des fichiers Nix. Un "module" home-manager déclare des
# options (ce qu'on peut régler) et la configuration qui en découle. Une fois ce fichier
# importé dans sa configuration, il suffit d'écrire :
#
#   services.jcvd-bot.enable = true;
#
# Ce que le module ne fait PAS : installer le projet. Le bot tourne toujours depuis le dépôt
# cloné, avec l'environnement Python créé par uv (.venv) et les secrets de .env (étapes 6 et 7
# de docs/DEPLOIEMENT_PI.md). Construire le projet lui-même avec Nix serait possible, mais
# demanderait de traduire uv.lock en paquets Nix (PyTorch compris) : beaucoup de complexité
# pour un gain faible ici. Le module ne remplace donc que la partie systemd.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.jcvd-bot;
in
{
  options.services.jcvd-bot = {
    enable = lib.mkEnableOption "le bot Telegram JCVD";

    directory = lib.mkOption {
      type = lib.types.str;
      # %h est remplacé par systemd par le dossier personnel (/home/<utilisateur>).
      default = "%h/projects/JeanClaude";
      description = "Dossier du dépôt cloné, qui contient .env et .venv.";
    };

    # uv fourni par Nix : sa version est fixée par la configuration de la machine, au lieu de
    # dépendre d'un uv installé à la main dans ~/.local/bin.
    package = lib.mkPackageOption pkgs "uv" { };
  };

  # lib.mkIf : cette configuration n'existe que si `enable = true`.
  config = lib.mkIf cfg.enable {
    # home-manager écrit ce service dans ~/.config/systemd/user/jcvd-bot.service, l'active au
    # démarrage et le relance quand sa définition change. Chaque réglage est expliqué dans
    # deploy/jcvd-bot.service.
    systemd.user.services.jcvd-bot = {
      Unit.Description = "Bot Telegram JCVD (RAG)";

      Service = {
        WorkingDirectory = cfg.directory;
        ExecStart = "${lib.getExe cfg.package} run --frozen --env-file .env jcvd telegram";
        Restart = "on-failure";
        RestartSec = 10;
        Environment = [
          "PYTHONUNBUFFERED=1"
          "TQDM_DISABLE=1"
        ];
      };

      # Démarre avec la session de l'utilisateur, ouverte dès le boot grâce à "linger".
      Install.WantedBy = [ "default.target" ];
    };
  };
}
