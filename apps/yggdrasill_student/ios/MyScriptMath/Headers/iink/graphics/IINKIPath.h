// Copyright @ MyScript. All rights reserved.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>


/**
 * The path interface, for building a path as described in the SVG
 * specifications.
 *
 * @see https://www.w3.org/TR/SVG/paths.html
 */
@protocol IINKIPath <NSObject>

@required

//==============================================================================
#pragma mark - Required Methods
//==============================================================================

/**
 * Starts a new subpath at the given position.
 *
 * @see https://www.w3.org/TR/SVG/paths.html#PathDataMovetoCommands
 *
 * @param position the coordinates to move to.
 */
- (void)moveTo:(CGPoint)position;

/**
 * Draws a line from the current point to the given position which
 * becomes the new current point.
 *
 * @see https://www.w3.org/TR/SVG/paths.html#PathDataLinetoCommands
 *
 * @param position the coordinate to draw a line to.
 */
- (void)lineTo:(CGPoint)position;

/**
 * Close the current subpath by drawing a straight line from the current point
 * to current subpath's initial point.
 *
 * @see https://www.w3.org/TR/SVG/paths.html#PathDataClosePathCommand
 */
- (void)closePath;


//==============================================================================
#pragma mark - Optional Methods
//==============================================================================

@optional

/**
 * Draws a cubic Bezier curve from the current point to anchor using the given
 * control points.
 *
 * @see https://www.w3.org/TR/SVG/paths.html#PathDataCurveCommands
 *
 * @param to the coordinates of the final point of the curve.
 * @param c1 the coordinates of the control point at the beginning of the curve.
 * @param c2 the coordinates of the control point at the end of the curve.
 */
- (void)curveTo:(CGPoint)to controlPoint1:(CGPoint)c1 controlPoint2:(CGPoint)c2;

/**
 * Draws a quadratic Bezier curve from the current point to anchor using
 * a control point.
 *
 * @see https://www.w3.org/TR/SVG/paths.html#PathDataQuadraticBezierCommands
 *
 * @param to the coordinates of the final point of the curve.
 * @param c the coordinates of the control point.
 */
- (void)quadTo:(CGPoint)to controlPoint:(CGPoint)c;

/**
 * Draws an elliptical arc from the current point to `to`. The size and
 * orientation of the ellipse are defined by two radii (rx, ry) and an
 * x-axis-rotation, which indicates how the ellipse as a whole is rotated
 * relative to the current coordinate system. The center (cx, cy) of the
 * ellipse is calculated automatically to satisfy the constraints imposed by
 * the other parameters.
 *
 * @see https://www.w3.org/TR/SVG/paths.html#PathDataEllipticalArcCommands
 *
 * @param to the coordinates of the last point.
 * @param rx the x-axis radius (must be positive).
 * @param ry the y-axis radius (must be positive).
 * @param phi the x-axis rotation angle.
 * @param fA the large-arc flag.
 * @param fS the sweep-arc flag.
 */
- (void)arcTo:(CGPoint)to rx:(float)rx ry:(float)ry phi:(float)phi fA:(BOOL)fA fS:(BOOL)fS;


@end
