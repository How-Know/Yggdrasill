// 임시: 표·수식 조각의 TeX 을 본다.
const { buildTexSource } = await import('./src/problem_bank/render_engine/xelatex_v2/template.js');
const build = (stem) => buildTexSource({ stem, choices: [], question_type: '주관식', meta: {} });
const body = (tex) => tex.slice(tex.indexOf('\\begin{document}'));
const diag = body(build(['다음 표를 보고 답하시오.', '[문단]', '[표시작]',
  '\\begin{tabular}{|c|c|c|}', '\\hline',
  '\\diagbox{\\text{지역 B}}{\\text{지역 A}} & \\text{희망함} & \\text{합계} \\\\', '\\hline',
  '\\text{희망함} & 140 & 450 \\\\', '\\hline', '\\end{tabular}', '[표끝]'].join('\n')));
for (const l of diag.split('\n').filter((x) => /tblcelwdA\}\{|diagbox/.test(x))) console.log('D>', l.slice(0, 700));
for (const stem of ['S=\\frac{2\\{1-|-2|^{5}\\}}{1-|-2|}의 값을 구하시오.', '집합 A=\\{x|x>0\\}의 원소를 구하시오.', '집합 B=\\{x||x|<3\\}의 원소를 구하시오.']) {
  for (const l of body(build(stem)).split('\n').filter((x) => /구하시오/.test(x))) console.log('S>', l.slice(0, 500));
}
