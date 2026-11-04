import 'package:assets_explorer/ui/format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('prettyName turns file names into titles', () {
    expect(prettyName('Knight_Idle-Anim.png'), 'Knight Idle Anim');
    expect(prettyName('walk-cycle_v2.png'), 'Walk cycle v2');
    expect(prettyName('  __weird--name__.gif '), 'Weird name');
    expect(prettyName('NPC_talk.png'), 'NPC talk');
    expect(prettyName('v1.2_hero.png'), 'V1.2 hero');
    expect(prettyName('.hidden'), '.hidden');
    expect(prettyName('___.png'), '___.png');
  });

  test('prettyName keeps dots in folder names', () {
    expect(
      prettyName('epic_rpg-world v1.6', isFile: false),
      'Epic rpg world v1.6',
    );
  });
}
