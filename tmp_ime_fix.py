import pathlib

def main():
  root = pathlib.Path('apps/yggdrasill/lib')
  target_import = "import 'package:mneme_flutter/utils/ime_aware_text_editing_controller.dart';"
  changed_files = []

  for path in root.rglob('*.dart'):
    if path.name == 'ime_aware_text_editing_controller.dart':
      continue
    text = path.read_text(encoding='utf-8')
    if 'TextEditingController(' not in text:
      continue
    new_text = text.replace('TextEditingController(', 'ImeAwareTextEditingController(')
    if new_text == text:
      continue
    path.write_text(new_text, encoding='utf-8')
    changed_files.append(path)

  for path in changed_files:
    text = path.read_text(encoding='utf-8')
    if target_import in text:
      continue
    lines = text.splitlines()
    insert_index = 0
    for i, line in enumerate(lines):
      if line.strip().startswith('import '):
        insert_index = i + 1
    lines.insert(insert_index, target_import)
    if text.endswith('\n'):
      lines.append('')
    path.write_text('\n'.join(lines), encoding='utf-8')

  print(f'Updated {len(changed_files)} files')

if __name__ == '__main__':
  main()



























