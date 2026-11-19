// v2.11.4 tests: Chats "Search chats" matches the @username too.
//
// Bug (verified live in the v2.11.3 retest, demo account): the
// Chats-list filter matched the display name only, so "yashsharma"
// showed "No chats yet" even though the Yash Sharma DM was in the
// list, while "yash sharma" (with a space) found it. The global
// "Find people" search already matches usernames (v2.11.2) and is
// NOT touched here — this is the Chats-list filter only.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifegame/data/messaging_models.dart';
import 'package:lifegame/data/messaging_service.dart';
import 'package:lifegame/screens/chats_screen.dart';

void main() {
  group('Chats search matches display name, username, group title', () {
    ConversationItem dm({
      required String id,
      required String otherUserId,
    }) => ConversationItem(
      conversation: Conversation(
        id: id,
        type: 'dm',
        createdBy: 'me',
        createdAt: DateTime(2026, 11, 19),
      ),
      unread: false,
      otherUserId: otherUserId,
    );

    ConversationItem group({required String id, required String title}) =>
        ConversationItem(
          conversation: Conversation(
            id: id,
            type: 'group',
            title: title,
            createdBy: 'me',
            createdAt: DateTime(2026, 11, 19),
          ),
          unread: false,
        );

    // The exact live case: display name "Yash Sharma", username
    // "yashsharma" (no space).
    late List<ConversationItem> items;
    String nameFor(ConversationItem item) {
      if (item.conversation.isGroup) {
        return item.conversation.title ?? 'Group chat';
      }
      return item.otherUserId == 'yash-id' ? 'Yash Sharma' : 'Muse Demo';
    }

    String? usernameFor(ConversationItem item) {
      if (item.otherUserId == 'yash-id') return 'yashsharma';
      if (item.otherUserId == 'demo-id') return 'muse_demo';
      return null;
    }

    setUp(() {
      items = [
        dm(id: 'dm-yash', otherUserId: 'yash-id'),
        dm(id: 'dm-demo', otherUserId: 'demo-id'),
        group(id: 'g1', title: 'Demo test group'),
      ];
    });

    List<String> ids(String query, {bool revealActive = false}) =>
        visibleChatItems(
          items: items,
          query: query,
          revealActive: revealActive,
          nameFor: nameFor,
          usernameFor: usernameFor,
        ).map((i) => i.conversation.id).toList();

    test('"yashsharma" (username, no space) finds the DM', () {
      expect(ids('yashsharma'), ['dm-yash']);
    });

    test('"yash sharma" (display name, with space) still finds the DM', () {
      expect(ids('yash sharma'), ['dm-yash']);
    });

    test('matching is case-insensitive', () {
      expect(ids('YASHSHARMA'), ['dm-yash']);
      expect(ids('Yash'), ['dm-yash']);
    });

    test('a leading @ is ignored', () {
      expect(ids('@yashsharma'), ['dm-yash']);
    });

    test('a group title substring finds the group', () {
      expect(ids('test group'), ['g1']);
      expect(ids('Demo test'), ['g1']);
    });

    test('a username substring of another DM finds only that DM', () {
      expect(ids('muse_demo'), ['dm-demo']);
      expect(ids('muse'), ['dm-demo']);
    });

    test('a non-matching query finds nothing', () {
      expect(ids('zzz-no-such-chat'), isEmpty);
      expect(ids('rishikaa'), isEmpty);
    });

    test('empty query shows everything', () {
      expect(ids(''), ['dm-yash', 'dm-demo', 'g1']);
    });

    test('hidden-chat reveal still bypasses the name/username filter', () {
      // The exact keyword "pineapple" must show the revealed rows
      // as-is, not filter them out (v2.11.2 FIX 2 / v2.11.3 FIX 3).
      expect(
        ids('pineapple', revealActive: true),
        ['dm-yash', 'dm-demo', 'g1'],
      );
    });

    test('works without a username callback (old callers)', () {
      final visible = visibleChatItems(
        items: items,
        query: 'yash',
        revealActive: false,
        nameFor: nameFor,
      );
      expect(visible.map((i) => i.conversation.id), ['dm-yash']);
    });
  });
}
