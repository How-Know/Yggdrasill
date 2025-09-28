import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class TenantService {
  TenantService._();
  static final TenantService instance = TenantService._();

  static const _prefsKey = 'active_academy_id';

  Future<String?> getActiveAcademyId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final id = prefs.getString(_prefsKey);
      if (id != null && id.isNotEmpty) return id;
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> setActiveAcademyId(String academyId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, academyId);
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

    // 2) try fast path: select by owner_user_id (allowed by updated policy)
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

    // 3) fallback: call RPC to create/find academy with SECURITY DEFINER
    final rpc = await client.rpc('ensure_academy');
    final id = rpc is String ? rpc : (rpc['ensure_academy'] as String?);
    if (id == null || id.isEmpty) {
      throw StateError('Failed to ensure academy id');
    }
    await setActiveAcademyId(id);
    return id;
  }
}



