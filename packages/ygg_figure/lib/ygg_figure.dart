/// Yggdrasill 그림 엔진.
///
/// 그림 파일(관계로 적은 JSON) → [buildFigure] → [Scene](그릴 조각 목록) → 인쇄([sceneToTikz])·화면.
library;

export 'src/expr.dart' show Expr, ExprError;
export 'src/edit.dart';
export 'src/figure.dart' show buildFigure, layoutFigure, FigureLayout, figureParams, FigureError, engineVersion, figureFormat;
export 'src/geom.dart' show P;
export 'src/scene.dart';
export 'src/size_table.dart';
export 'src/sizing.dart';
export 'src/style.dart' show FigureStyle;
export 'src/tags.dart';
export 'src/tikz.dart' show sceneToTikz, standaloneDocument;
