import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class TenantService {
  TenantService._();
  static final TenantService instance = TenantService._();

  static const _prefsKey = 'active_academy_id';
  static String _scopedPrefsKey(String uid) => 'active_academy_id_$uid';

  Future<String?> getActiveAcademyId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final uid = Supabase.instance.client.auth.currentUser?.id;
      if (uid == null || uid.isEmpty) {
        final id = prefs.getString(_prefsKey);
        if (id != null && id.isNotEmpty) return id;
        return null;
      }
      final scoped = prefs.getString(_scopedPrefsKey(uid));
      if (scoped != null && scoped.isNotEmpty) return scoped;

      // Legacy migration: only accept if user is a member of that academy
      final legacy = prefs.getString(_prefsKey);
      if (legacy != null && legacy.isNotEmpty) {
        final ok = await _hasMembership(uid, legacy);
        if (ok) {
          await prefs.setString(_scopedPrefsKey(uid), legacy);
          return legacy;
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> setActiveAcademyId(String academyId) async {
    final prefs = await SharedPreferences.getInstance();
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid != null && uid.isNotEmpty) {
      await prefs.setString(_scopedPrefsKey(uid), academyId);
    }
  }

  Future<bool> _hasMembership(String uid, String academyId) async {
    try {
      final rows = await Supabase.instance.client
          .from('memberships')
          .select('id')
          .eq('academy_id', academyId)
          .eq('user_id', uid)
          .limit(1);
      return rows.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Ensure an academy exists for current user (as owner) and return its id.
  /// If none exists, create one and store as active.
  Future<String> ensureActiveAcademy() async {
    final client = Supabase.instance.client;
    final uid = client.auth.currentUser?.id;
    if (uid == null || uid.isEmpty) {
      throw StateError('No logged-in user');
    }
    // 1) local prefs
    final existing = await getActiveAcademyId();
    if (existing != null) return existing;

    // 2) try memberships first: if the user is a member of an academy, use it
    try {
      final mem = await client
          .from('memberships')
          .select('academy_id')
          .eq('user_id', uid)
          .limit(1);
      if (mem.isNotEmpty && mem.first['academy_id'] is String) {
        final id = mem.first['academy_id'] as String;
        await setActiveAcademyId(id);
        return id;
      }
    } catch (_) {}

    // 3) then select by owner_user_id (owner path)
    try {
      final sel = await client
          .from('academies')
          .select('id')
          .eq('owner_user_id', uid)
          .limit(1);
      if (sel.isNotEmpty && sel.first['id'] is String) {
        final id = sel.first['id'] as String;
        await setActiveAcademyId(id);
        return id;
      }
    } catch (_) {
      // ignore and fallback to RPC
    }

    // 4) fallback: call RPC to create/find academy with SECURITY DEFINER
    final rpc = await client.rpc('ensure_academy');
    final id = rpc is String ? rpc : (rpc['ensure_academy'] as String?);
    if (id == null || id.isEmpty) {
      throw StateError('Failed to ensure academy id');
    }
    await setActiveAcademyId(id);
    return id;
  }

  /// Check if current auth user is the owner of the active academy.
  /// Returns false if not logged in, no active academy, or any error occurs.
  Future<bool> isOwnerOfActiveAcademy() async {
    try {
      final client = Supabase.instance.client;
      final uid = client.auth.currentUser?.id;
      if (uid == null || uid.isEmpty) return false;
      final aid = await getActiveAcademyId();
      if (aid == null || aid.isEmpty) return false;
      final sel = await client
          .from('academies')
          .select('owner_user_id')
          .eq('id', aid)
          .limit(1);
      if (sel.isEmpty) return false;
      final ownerId = sel.first['owner_user_id'] as String?;
      return ownerId == uid;
    } catch (_) {
      return false;
    }
  }

  /// Check if current auth user is a platform superadmin.
  /// Strategy:
  /// 1) Try querying `app_users` table (if exists) for `platform_role = 'superadmin'`.
  /// 2) Fallback to environment allowlist by email: SUPERADMIN_EMAILS (comma-separated).
  Future<bool> isSuperAdmin() async {
    try {
      final client = Supabase.instance.client;
      final uid = client.auth.currentUser?.id;
      if (uid == null || uid.isEmpty) return false;
      // 0) Prefer RPC to bypass RLS issues
      try {
        final r = await client.rpc('is_superadmin');
        if (r is bool) return r;
        if (r is Map && r.values.isNotEmpty && r.values.first is bool) {
          return r.values.first as bool;
        }
      } catch (_) {
        // ignore and fallback
      }
      try {
        final rows = await client
            .from('app_users')
            .select('platform_role')
            .eq('user_id', uid)
            .limit(1);
        if (rows.isNotEmpty) {
          final role = (rows.first['platform_role'] as String?)?.toLowerCase().trim();
          if (role == 'superadmin') return true;
        }
      } catch (_) {
        // Table may not exist yet; ignore and fallback.
      }
      final allow = const String.fromEnvironment('SUPERADMIN_EMAILS', defaultValue: '');
      if (allow.trim().isEmpty) return false;
      final currentEmail = client.auth.currentUser?.email?.toLowerCase().trim();
      if (currentEmail == null || currentEmail.isEmpty) return false;
      final set = allow.split(',').map((s) => s.toLowerCase().trim()).where((s) => s.isNotEmpty).toSet();
      return set.contains(currentEmail);
    } catch (_) {
      return false;
    }
  }
}



