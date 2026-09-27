// Talking to your WakeBack server's accounts: sign up, log in, who am I, friends.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class AuthException implements Exception {
  final String message;
  final int status;
  const AuthException(this.message, [this.status = 0]);
  @override
  String toString() => message;
}

class Account {
  final int id;
  final String email, name, role, status;
  const Account(this.id, this.email, this.name, this.role, this.status);
  bool get isAdmin => role == 'admin';
  static Account fromJson(Map<String, dynamic> j) =>
      Account((j['id'] as num?)?.toInt() ?? 0, '${j['email'] ?? ''}', '${j['name'] ?? ''}', '${j['role'] ?? 'user'}', '${j['status'] ?? ''}');
  Map<String, dynamic> toJson() => {'id': id, 'email': email, 'name': name, 'role': role, 'status': status};
}

class Friend {
  final int id;
  final String name, email, status;
  final bool requestedByMe;
  const Friend(this.id, this.name, this.email, this.status, this.requestedByMe);
  static Friend fromJson(Map<String, dynamic> j) {
    final u = (j['user'] as Map?)?.cast<String, dynamic>() ?? const {};
    return Friend((j['id'] as num).toInt(), '${u['name'] ?? ''}', '${u['email'] ?? ''}', '${j['status'] ?? ''}', j['requested_by_me'] == true);
  }
}

class FriendLists {
  final List<Friend> friends, incoming, outgoing;
  const FriendLists(this.friends, this.incoming, this.outgoing);
}

/// Result of a sign-in or sign-up: either a token or "pending".
class SignInResult {
  final String? token;
  final Account user;
  const SignInResult(this.token, this.user);
  bool get pending => token == null;
}

class AuthApi {
  final String base;
  final String? token;
  AuthApi(String url, {this.token}) : base = url.trim().replaceAll(RegExp(r'/+$'), '');

  static const _timeout = Duration(seconds: 20);
  Uri _u(String p) => Uri.parse('$base$p');
  Map<String, String> get _h => {'Content-Type': 'application/json', if (token != null) 'Authorization': 'Bearer $token'};

  Future<Map<String, dynamic>> _json(Future<http.Response> f) async {
    http.Response r;
    try {
      r = await f.timeout(_timeout);
    } on TimeoutException {
      throw const AuthException('The server didn\'t answer. Check the address and your signal.');
    } catch (e) {
      throw AuthException('Can\'t reach the server: $e');
    }
    Map<String, dynamic> j;
    try {
      j = (jsonDecode(utf8.decode(r.bodyBytes)) as Map).cast<String, dynamic>();
    } catch (_) {
      if (r.statusCode == 302 || r.statusCode == 301 || (r.headers['location'] ?? '').contains('cloudflareaccess')) {
        throw AuthException('Something in front of the server (Cloudflare Access?) is asking for its own login. '
            'Limit it to the /admin page, or turn it off for this address.', r.statusCode);
      }
      throw AuthException('Unexpected reply (HTTP ${r.statusCode}). Is that a WakeBack server?', r.statusCode);
    }
    if (r.statusCode >= 400) throw AuthException('${j['error'] ?? 'HTTP ${r.statusCode}'}', r.statusCode);
    return j;
  }

  /// Does this server have accounts switched on?
  Future<bool> hasAccounts() async {
    try {
      final r = await http.get(_u('/api/auth/me')).timeout(_timeout);
      if (r.statusCode == 401) return true;
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      return j is Map && j['accounts'] == true;
    } on TimeoutException {
      throw const AuthException('The server didn\'t answer. Check the address and your signal.');
    } catch (e) {
      if (e is AuthException) rethrow;
      throw AuthException('Can\'t reach the server: $e');
    }
  }

  Future<SignInResult> signup(String email, String name, String password, {String device = 'phone'}) async {
    final j = await _json(http.post(_u('/api/auth/signup'),
        headers: _h, body: jsonEncode({'email': email, 'name': name, 'password': password, 'device': device})));
    return SignInResult(j['token'] as String?, Account.fromJson((j['user'] as Map).cast<String, dynamic>()));
  }

  Future<SignInResult> login(String email, String password, {String device = 'phone'}) async {
    final j = await _json(http.post(_u('/api/auth/login'), headers: _h, body: jsonEncode({'email': email, 'password': password, 'device': device})));
    return SignInResult(j['token'] as String?, Account.fromJson((j['user'] as Map).cast<String, dynamic>()));
  }

  /// For the "waiting for approval" screen: token once approved, else null.
  Future<SignInResult?> checkApproved(String email, String password, {String device = 'phone'}) async {
    final j = await _json(http.post(_u('/api/auth/status'), headers: _h, body: jsonEncode({'email': email, 'password': password, 'device': device})));
    if (j['token'] == null) return null;
    return SignInResult(j['token'] as String, Account.fromJson((j['user'] as Map).cast<String, dynamic>()));
  }

  Future<Account> me() async {
    final j = await _json(http.get(_u('/api/auth/me'), headers: _h));
    return Account.fromJson((j['user'] as Map).cast<String, dynamic>());
  }

  Future<void> logout() async {
    try {
      await http.post(_u('/api/auth/logout'), headers: _h).timeout(const Duration(seconds: 8));
    } catch (_) {}
  }

  Future<void> changePassword(String oldPw, String newPw) async {
    await _json(http.post(_u('/api/auth/password'), headers: _h, body: jsonEncode({'old': oldPw, 'new': newPw})));
  }

  Future<FriendLists> friends() async {
    final j = await _json(http.get(_u('/api/friends'), headers: _h));
    List<Friend> l(String k) => ((j[k] as List?) ?? const []).map((e) => Friend.fromJson((e as Map).cast<String, dynamic>())).toList();
    return FriendLists(l('friends'), l('incoming'), l('outgoing'));
  }

  /// Returns 'pending' or 'accepted' (if they'd already asked you).
  Future<String> requestFriend(String email) async {
    final j = await _json(http.post(_u('/api/friends/request'), headers: _h, body: jsonEncode({'email': email})));
    return '${j['status']}';
  }

  Future<void> acceptFriend(int id) => _json(http.post(_u('/api/friends/$id/accept'), headers: _h));
  Future<void> declineFriend(int id) => _json(http.post(_u('/api/friends/$id/decline'), headers: _h));
  Future<void> unfriend(int id) => _json(http.delete(_u('/api/friends/$id'), headers: _h));
}
