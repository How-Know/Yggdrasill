// Copyright @ MyScript. All rights reserved.

#import <Foundation/Foundation.h>
#import <iink/IINKEditor.h>

/**
 * Describes the tools that the pointer types can be associated with.
 */
typedef NS_ENUM(NSUInteger, IINKPointerTool)
{
  /** Pen Pointer Tool */
  IINKPointerToolPen         = 0,
  /** Hand Pointer Tool */
  IINKPointerHand            = 1,
  /** Eraser Pointer Tool */
  IINKPointerEraser          = 2,
  /** Selector Pointer Tool */
  IINKPointerToolSelector    = 3,
  /** Highlighter Pointer Tool */
  IINKPointerToolHighlighter = 4,

};

/**
 * Wrapper object for an `IINKPointerTool` value.
 * it's purpose is to accept nullable parameter, in order to make toolForType method throwable in Swift
 */
@interface IINKPointerToolWrapper : NSObject
{
}

@property (nonatomic) IINKPointerTool value;

/**
 * Create a new `IINKPointerToolWrapper` instance.
 * @param value the IINKPointerTool value.
 */
- (nullable instancetype)initWithValue:(IINKPointerTool)value;

/**
 * Builds a new `IINKPointerToolWrapper` instance.
 * @param value the BOOL value.
 */
+ (nonnull IINKPointerToolWrapper *)createWithValue:(IINKPointerTool)value;

@end

/**
 * The ToolController manages pointer tools configuration.
 *
 * @see IINKEditor.
 */
@interface IINKToolController : NSObject
{

}

//==============================================================================
#pragma mark - Tool Manipulation
//==============================================================================

/**
 * Returns the tool associated with a pointer type.
 * @param type the pointer type.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when `type` is invalid.
 * @return the pointer tool associated with this type.
 */

- (nullable IINKPointerToolWrapper *)toolForType:(IINKPointerType)type
                                           error:(NSError * _Nullable * _Nullable)error
                                     NS_SWIFT_NAME(tool(forType:));

/**
 * Sets the tool associated with a pointer type.
 *
 * @param tool the pointer tool.
 * @param type the pointer type.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when `type` is invalid.
 *   * IINKErrorInvalidArgument when `tool` is invalid.
 *   * IINKErrorPointerSequence when a pointer event sequence is in progress with
 *   this pointer type.
 */
- (BOOL)setTool:(IINKPointerTool)tool
        forType:(IINKPointerType)type
          error:(NSError * _Nullable * _Nullable)error
        NS_SWIFT_NAME(set(tool:forType:));

/**
 * Returns the CSS style properties associated with a pointer tool.
 * @param tool the pointer tool.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when `tool` is invalid.
 * @return the CSS style properties associated with this pointer tool.
 */
- (nullable NSString *)toolStyle:(IINKPointerTool)tool
                           error:(NSError * _Nullable * _Nullable)error
                      NS_SWIFT_NAME(style(forTool:));

/**
 * Sets the CSS style properties associated with a pointer tool.
 * @param style the tool CSS style properties.
 * @param tool the pointer tool.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when `tool` is invalid.
 *   * IINKErrorPointerSequence when a pointer event sequence is in progress with
 *     a different tool (e.g. Eraser).
 */

- (BOOL)setStyle:(nonnull NSString *)style
         forTool:(IINKPointerTool)tool
           error:(NSError * _Nullable * _Nullable)error
        NS_SWIFT_NAME(set(style:forTool:));

/**
 * Returns the style classes associated with a pointer tool.
 * @param tool the pointer tool.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when `tool` is invalid.
 * @return the style classes associated with this pointer tool.
 */
- (nullable NSString *)toolStyleClasses:(IINKPointerTool)tool
                                 error:(NSError * _Nullable * _Nullable)error
                      NS_SWIFT_NAME(styleClasses(forTool:));

/**
 * Sets the style classes associated with a pointer tool.
 * @note style properties provided via `setToolStyle()` may override the
 *   styling associated with the style classes provided here.
 * @param styleClasses the style class names, separated by spaces.
 * @param tool the pointer tool.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when `tool` is invalid.
 */
-(BOOL)setStyleClasses:(nonnull NSString *)styleClasses
               forTool:(IINKPointerTool)tool
                 error:(NSError * _Nullable * _Nullable)error
       NS_SWIFT_NAME(set(styleClasses:forTool:));

@end
