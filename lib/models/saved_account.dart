class SavedAccount {
  const SavedAccount({
    required this.username,
    this.nickname = '',
    this.avatar = '',
    this.authenticationDomain = '',
    this.automaticDomain = true,
  });

  final String username, nickname, avatar, authenticationDomain;
  final bool automaticDomain;
  String get id => username.trim().toLowerCase();
  String get label => nickname.isEmpty ? username : nickname;

  factory SavedAccount.fromRow(Map<String, Object?> row) => SavedAccount(
    username: row['username']! as String,
    nickname: row['nickname']! as String,
    avatar: row['avatar']! as String,
    authenticationDomain: row['authentication_domain']! as String,
    automaticDomain: row['automatic_domain'] == 1,
  );

  Map<String, Object?> toRow() => {
    'account_key': id,
    'username': username,
    'nickname': nickname,
    'avatar': avatar,
    'authentication_domain': authenticationDomain,
    'automatic_domain': automaticDomain ? 1 : 0,
  };
}
