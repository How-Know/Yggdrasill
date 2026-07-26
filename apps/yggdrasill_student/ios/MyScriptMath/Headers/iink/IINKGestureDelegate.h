// Copyright @ MyScript. All rights reserved.

#import <Foundation/Foundation.h>
#import <iink/IINKToolController.h>

@class IINKEditor;

/**
 * Action to perform upon gesture notification.
 */
typedef NS_ENUM(NSUInteger, IINKGestureAction)
{
  /** Apply the gesture behavior, as configured in the editor. */
  IINKGestureActionApply,
  /** Discard the gesture stroke, do not apply the gesture behavior. */
  IINKGestureActionIgnore,
  /** Do not apply the gesture behavior and add gesture stroke as a regular stroke (if relevant). */
  IINKGestureActionAdd,
};

/**
 * Action type associated with a shape on hold event.
 *
 * @since 4.3
 */
typedef NS_ENUM(NSUInteger, IINKShapeOnHoldAction)
{
  /** Shape has been displayed while holding. */
  IINKShapeOnHoldActionDisplayed,
  /** Shape has been applied after pointer up. */
  IINKShapeOnHoldActionApplied,
  /** Shape previously shown has been canceled (for example after pointer move). */
  IINKShapeOnHoldActionCanceled,
};

/**
 * The delegate interface for handling gesture events.
 *
 * @see IINKEditor
 */
@protocol IINKGestureDelegate <NSObject>

@required

//==============================================================================
#pragma mark - Required Methods
//==============================================================================

/**
 * Invoked when a tap has been detected.
 *
 * @param editor the editor.
 * @param tool the tool used to perform the gesture.
 * @param gestureStrokeId the id of the gesture stroke.
 * @param x the tap x position (view coordinate in px).
 * @param y the tap y position (view coordinate in px).
 * @return the IINKGestureAction to perform.
 */
- (IINKGestureAction)onTap:(nonnull IINKEditor*)editor
                      tool:(IINKPointerTool)tool
           gestureStrokeId:(nonnull NSString*)gestureStrokeId
                         x:(float)x
                         y:(float)y;

/**
 * Invoked when a double tap has been detected.
 *
 * @param editor the editor.
 * @param tool the tool used to perform the gesture.
 * @param gestureStrokeIds the id of the gesture strokes.
 * @param x the double tap x position (view coordinate in px).
 * @param y the double tap y position (view coordinate in px).
 * @return the IINKGestureAction to perform.
 */
- (IINKGestureAction)onDoubleTap:(nonnull IINKEditor*)editor
                            tool:(IINKPointerTool)tool
                gestureStrokeIds:(nonnull NSArray<NSString *> *)gestureStrokeIds
                               x:(float)x
                               y:(float)y;

/**
 * Invoked when a long press has been detected.
 *
 * @param editor the editor.
 * @param tool the tool used to perform the gesture.
 * @param gestureStrokeId the id of the gesture stroke.
 * @param x the long press x position (view coordinate in px).
 * @param y the long press y position (view coordinate in px).
 * @return the IINKGestureAction to perform.
 */
- (IINKGestureAction)onLongPress:(nonnull IINKEditor*)editor
                            tool:(IINKPointerTool)tool
                 gestureStrokeId:(nonnull NSString*)gestureStrokeId
                               x:(float)x
                               y:(float)y;

/**
 * Invoked when a portion of text has been underlined.
 *
 * To activate underline detection in a Raw Content part, add "underline" to the
 * "raw-content.pen.gestures" configuration list.
 *
 * @param editor the editor.
 * @param tool the tool used to perform the gesture.
 * @param gestureStrokeId the id of the gesture stroke.
 * @param selection the underlined portion of text.
 * @return the IINKGestureAction to perform.
 */
- (IINKGestureAction)onUnderline:(nonnull IINKEditor*)editor
                            tool:(IINKPointerTool)tool
                 gestureStrokeId:(nonnull NSString*)gestureStrokeId
                       selection:(nonnull NSObject<IINKIContentSelection>*)selection;

/**
 * Invoked when a portion of text has been surrounded.
 *
 * To activate surround detection in a Raw Content part, add "surround" to
 * the "raw-content.pen.gestures" configuration list.
 *
 * @param editor the editor.
 * @param tool the tool used to perform the gesture.
 * @param gestureStrokeId the id of the gesture stroke.
 * @param selection the surrounded portion of text.
 * @return the IINKGestureAction to perform.
 */
- (IINKGestureAction)onSurround:(nonnull IINKEditor*)editor
                           tool:(IINKPointerTool)tool
                gestureStrokeId:(nonnull NSString*)gestureStrokeId
                      selection:(nonnull NSObject<IINKIContentSelection>*)selection;

/**
 * Invoked when a join gesture has been drawn between two portions of a text line,
 * or at the beginning or end of a line.
 *
 * To activate join detection in a Raw Content part, add "join" to the
 * "raw-content.pen.gestures" configuration list.
 *
 * @param editor the editor.
 * @param tool the tool used to perform the gesture.
 * @param gestureStrokeId the id of the gesture stroke.
 * @param before the portion of the text line before the join gesture.
 * @param after the portion of the text line after the join gesture.
 * @return the IINKGestureAction to perform.
 */
- (IINKGestureAction)onJoin:(nonnull IINKEditor*)editor
                       tool:(IINKPointerTool)tool
            gestureStrokeId:(nonnull NSString*)gestureStrokeId
                     before:(nonnull NSObject<IINKIContentSelection>*)before
                      after:(nonnull NSObject<IINKIContentSelection>*)after;

/**
 * Invoked when an insert gesture has been drawn between two portions of a text line,
 * or at the beginning or end of a line.
 *
 * To activate insert detection in a Raw Content part, add "insert" to the
 * "raw-content.pen.gestures" configuration list.
 *
 * @param editor the editor.
 * @param tool the tool used to perform the gesture.
 * @param gestureStrokeId the id of the gesture stroke.
 * @param before the portion of the text line before the insert gesture.
 * @param after the portion of the text line after the insert gesture.
 * @return the IINKGestureAction to perform.
 */
- (IINKGestureAction)onInsert:(nonnull IINKEditor*)editor
                         tool:(IINKPointerTool)tool
              gestureStrokeId:(nonnull NSString*)gestureStrokeId
                       before:(nonnull NSObject<IINKIContentSelection>*)before
                        after:(nonnull NSObject<IINKIContentSelection>*)after;

/**
 * Invoked when a portion of text has been striked through.
 *
 * To activate strikethrough detection in a Raw Content part, add "strike-through"
 * "raw-content.pen.gestures" configuration list.
 *
 * @param editor the editor.
 * @param tool the tool used to perform the gesture.
 * @param gestureStrokeId the id of the gesture stroke.
 * @param selection the striked through portion of text.
 * @return the IINKGestureAction to perform.
 */
- (IINKGestureAction)onStrikethrough:(nonnull IINKEditor*)editor
                                tool:(IINKPointerTool)tool
                     gestureStrokeId:(nonnull NSString*)gestureStrokeId
                           selection:(nonnull NSObject<IINKIContentSelection>*)selection;

/**
 * Invoked when a portion of text has been scratched.
 *
 * To activate scratch detection in a Raw Content part, add "scratch-out" to
 * the "raw-content.pen.gestures" configuration list.
 *
 * @param editor the editor.
 * @param tool the tool used to perform the gesture.
 * @param gestureStrokeId the id of the gesture stroke.
 * @param selection the scratched portion of text.
 * @return the IINKGestureAction to perform.
 */
- (IINKGestureAction)onScratch:(nonnull IINKEditor*)editor
                          tool:(IINKPointerTool)tool
               gestureStrokeId:(nonnull NSString*)gestureStrokeId
                     selection:(nonnull NSObject<IINKIContentSelection>*)selection;

@optional

//==============================================================================
#pragma mark - Optional Methods
//==============================================================================

/**
 * Invoked when a shape on hold action has been triggered.
 *
 * To activate shape on hold detection in a Raw Content part, set
 * "raw-content.convert.shape-on-hold" to true.
 *
 * @param editor the editor.
 * @param tool the tool used to perform the gesture.
 * @param gestureStrokeId the id of the gesture stroke.
 * @param action the type of action.
 * @param shapeJiix the JIIX description of the shape, empty for IINKShapeOnHoldActionCanceled.
 *
 * @since 4.3
 */
- (void)onShapeHold:(nonnull IINKEditor*)editor
              tool:(IINKPointerTool)tool
   gestureStrokeId:(nonnull NSString*)gestureStrokeId
            action:(IINKShapeOnHoldAction)action
         shapeJiix:(nonnull NSString*)shapeJiix;

@end
