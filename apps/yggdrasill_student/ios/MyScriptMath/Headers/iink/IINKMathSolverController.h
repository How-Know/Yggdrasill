// Copyright @ MyScript. All rights reserved.

#import <Foundation/Foundation.h>
#import <iink/IINKParameterSet.h>
#import <iink/IINKMimeType.h>

@class IINKMathExternalExpression;

//==============================================================================
#pragma mark - Associated Types
//==============================================================================

//==============================================================================
// MathDiagnostic
//==============================================================================

/**
 * Error code returned by `getDiagnostic()`.
 *
 * @since 4.1
 */
typedef NS_ENUM(NSUInteger, IINKMathDiagnostic)
{
  /** The task is allowed. */
  IINKMathDiagnosticAllowed                        = 0,
  /** The task is allowed but the user previously discarded the result. */
  IINKMathDiagnosticAllowedButPreviouslyDiscarded  = 1,
  /** The task is unsupported (internal error). */
  IINKMathDiagnosticUnsupported                    = 2,
  /** The expression form is not evaluable. */
  IINKMathDiagnosticNonEvaluable                   = 3,
  /** The expression is incomplete. */
  IINKMathDiagnosticIncompleteExpression           = 4,
  /** There is no undefined variable to evaluate. */
  IINKMathDiagnosticNoVariable                     = 5,
  /** There are too many undefined variables. */
  IINKMathDiagnosticTooManyVariables               = 6,
  /** Task does not apply or nothing to do, in respect to the current configuration. */
  IINKMathDiagnosticNotApplicable                  = 7,
  /** Computation leads to a division by zero. */
  IINKMathDiagnosticDivisionByZero                 = 8,
  /** Computation leads to a number overflow. */
  IINKMathDiagnosticNumberOverflow                 = 9,
  /** Computation leads to a number underflow. */
  IINKMathDiagnosticNumberUnderflow                = 10,
  /** Computation leads to an invalid operation. */
  IINKMathDiagnosticInvalidOperation               = 11,
};

//==============================================================================
// MathDiagnosticValue
//==============================================================================

/**
 * Wrapper object for an `IINKMathDiagnostic` value.
 */
@interface IINKMathDiagnosticValue : NSObject
{

}

@property (nonatomic) IINKMathDiagnostic value;

/**
 * Creates a new `IINKMathDiagnosticValue` instance.
 * @param value the error value.
 */
- (nullable instancetype)initWithValue:(IINKMathDiagnostic)value;

/**
 * Builds a new `IINKMathDiagnosticValue` instance.
 * @param value the error value.
 */
+ (nonnull IINKMathDiagnosticValue *)valueWithError:(IINKMathDiagnostic)value;

@end

//==============================================================================
// MathVariableSourceType
//==============================================================================

/**
 * Enumerates the possible sources from which a variable can be defined.
 *
 * @note `IINKMathVariableSourceTypeAPI` variables have priority over `IINKMathVariableSourceTypeBlock` variables, which have priority over `IINKMathVariableSourceTypeAPIGlobal` variables.
 *   `IINKMathVariableSourceTypePredefined` variables cannot be redefined.
 *
 * @since 4.1
 */
typedef NS_ENUM(NSUInteger, IINKMathVariableSourceType)
{
  /** The variable has not been defined. */
  IINKMathVariableSourceTypeUndefined  = 0,

  /** The local variable was defined through `IINKMathSolverController::setVariableValue(blockId, ...)`. */
  IINKMathVariableSourceTypeAPI        = 1,
  /** The global variable was defined through `IINKMathSolverController::setVariableValue("", ...)`. */
  IINKMathVariableSourceTypeAPIGlobal  = 2,
  /** The variable was defined through a block expression. */
  IINKMathVariableSourceTypeBlock      = 3,
  /** The variable is a predefined constant (e.g. `Pi`). */
  IINKMathVariableSourceTypePredefined = 4,
};

//==============================================================================
// MathVariableSourceTypeValue
//==============================================================================

/**
 * Wrapper object for an `IINKMathVariableSourceType` value.
 */
@interface IINKMathVariableSourceTypeValue : NSObject
{

}

@property (nonatomic) IINKMathVariableSourceType value;

/**
 * Creates a new `IINKMathVariableSourceTypeValue` instance.
 * @param value the source type value.
 */
- (nullable instancetype)initWithValue:(IINKMathVariableSourceType)value;

/**
 * Builds a new `IINKMathVariableSourceTypeValue` instance.
 * @param value the source type value.
 */
+ (nonnull IINKMathVariableSourceTypeValue *)valueWithError:(IINKMathVariableSourceType)value;

@end

//==============================================================================
// MathVariableInfo
//==============================================================================

/**
 * Represents a math variable information, relative to a block or global.
 *
 * @since 4.1
 */
@interface IINKMathVariableInfo : NSObject
{

}

- (nonnull instancetype) init:(nonnull NSString *)name :(IINKMathVariableSourceType)sourceType :(nullable NSString *)sourceId :(int)occurrenceCount;

/** The name of the variable. */
@property (nonatomic, readonly, nonnull) NSString *name;

/** The source from which the variable was defined, or `IINKMathVariableSourceType::undefined`. */
@property (nonatomic, readonly) IINKMathVariableSourceType sourceType;

/** The identifier of the block where the variable was defined, or an empty string if not applicable. */
@property (nonatomic, readonly, nonnull) NSString *sourceId;

/** The number of times the variable appears in the block expression. */
@property (nonatomic, readonly) int occurrenceCount;

@end

//==============================================================================
// MathVariableDefinition
//==============================================================================

/**
 * Represents a math variable definition.
 *
 * @since 4.1
 */
@interface IINKMathVariableDefinition : NSObject
{

}

- (nonnull instancetype) init:(nonnull NSString *)name :(double)value;

/**
 * Returns `YES` if the block given to `asVariableDefinition()` actually is a variable definition.
 */
- (BOOL)valid;

/** The name of the variable, empty if not valid. */
@property (nonatomic, readonly, nonnull) NSString *name;

/** The value of the variable. */
@property (nonatomic, readonly) double value;

@end

//==============================================================================
// MathVariableDefinitionInfo
//==============================================================================

/**
 * Represents a math variable definition info.
 *
 * @since 4.2
 */
@interface IINKMathVariableDefinitionInfo : NSObject
{

}

- (nonnull instancetype) init:(double)value :(IINKMathVariableSourceType)sourceType :(nonnull NSString *)blockId;

/** The value associated with the definition. */
@property (nonatomic, readonly) double value;

/** The source type associated with the definition. */
@property (nonatomic, readonly) IINKMathVariableSourceType sourceType;

/** The block id the variable is: used by (for `IINKMathVariableSourceTypeAPI`), defined by (for `IINKMathVariableSourceTypeBlock`) or empty (for `IINKMathVariableSourceTypeAPIGlobal`). */
@property (nonatomic, readonly, nonnull) NSString *blockId;

@end

//==============================================================================
// MathVariableDefinitions
//==============================================================================

/**
 * Represents the definitions associated with a math variable name.
 *
 * @since 4.2
 */
@interface IINKMathVariableDefinitions : NSObject
{

}

- (nonnull instancetype) init:(nonnull NSString *)name :(nonnull NSArray<IINKMathVariableDefinitionInfo *> *)definitions;

/** The name of the variable. */
@property (nonatomic, readonly, nonnull) NSString *name;

/** The info associated with the definitions. */
@property (nonatomic, readonly, nonnull) NSArray<IINKMathVariableDefinitionInfo *>* definitions;

@end

//==============================================================================
// MathEvaluationVariables
//==============================================================================

/**
 * Represents a pair of input/output math variables used for evaluation.
 * Example: for `"y = x^2 - 3x + 2"`, `getEvaluables()` returns `{ inputName = "x"; outputName = "y" }`.
 *
 * @since 4.1
 */
@interface IINKMathEvaluationVariables : NSObject
{

}

- (nonnull instancetype) init:(nonnull NSString *)inputName :(nonnull NSString *)outputName;

/** The name of the varying variable, empty for a constant expression. */
@property (nonatomic, readonly, nonnull) NSString *inputName;

/** The name of the result variable, empty for a single-variable expression without equal sign. */
@property (nonatomic, readonly, nonnull) NSString *outputName;

@end

//==============================================================================
// MathSolverController
//==============================================================================

/**
 * The MathSolverController allows to configure and run math operations on an editor.
 *
 * @note following limitation applies: the part managed by the associated
 *   editor must be a "Raw Content" and the specified block must be a
 *   "Math" block.
 *
 * @since 4.0
 */
@interface IINKMathSolverController : NSObject
{

}

//==============================================================================
#pragma mark - Methods
//==============================================================================

/**
 * Returns the available actions for the specified block.
 *
 * @param blockId the identifier of the block.
 * @param overrideConfiguration the extra configuration used.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when `blockId` is invalid.
 *   * IINKErrorInvalidArgument when `overrideConfiguration` is invalid.
 *   * IINKErrorRuntime when associated part type is not "Raw Content" or block type is not "Math".
 *
 * @return an array of the available actions.
 */
- (nullable NSArray<NSString *> *)getAvailableActions:(nonnull NSString *)blockId
                                overrideConfiguration:(nullable IINKParameterSet *)overrideConfiguration
                                                error:(NSError * _Nullable * _Nullable)error
                                          NS_SWIFT_NAME(availableActions(forBlock:overrideConfiguration:));

/**
 * Returns the output for the given action and the specified block.
 *
 * @param blockId the identifier of the block.
 * @param action the action operated by the math solver.
 * @param mimeType the MIME type that specifies the output format, either `JIIX` or `LATEX`.
 * @param overrideConfiguration the extra configuration used.
 * @param error the recipient for the error description object
 * * IINKErrorInvalidArgument when `blockId` is invalid.
 * * IINKErrorInvalidArgument when `action` is invalid.
 * * IINKErrorInvalidArgument when the specified MIME type is not supported.
 * * IINKErrorInvalidArgument when `overrideConfiguration` is invalid.
 * * IINKErrorRuntime when associated part type is not "Raw Content" or block type is not "Math".
 *
 * @return a string representing the output formatted with the given MIME type.
 */
- (nullable NSString *)getActionOutput:(nonnull NSString *)blockId
                                action:(nonnull NSString *)action
                              mimeType:(IINKMimeType)mimeType
                 overrideConfiguration:(nullable IINKParameterSet *)overrideConfiguration
                                 error:(NSError * _Nullable * _Nullable)error
                           NS_SWIFT_NAME(actionOutput(forBlock:action:mimeType:overrideConfiguration:));

/**
 * Applies the solved action of the specified block to the rendering.
 *
 * @note following limitation applies: incompatible with Offscreen interactivity service.
 *
 * @param blockId the identifier of the block.
 * @param action the action used by the math solver.
 * @param overrideConfiguration the extra configuration used.
 * @param error the recipient for the error description object
 *  * IINKErrorInvalidArgument when `blockId` is invalid.
 *  * IINKErrorInvalidArgument when `action` is invalid.
 *  * IINKErrorInvalidArgument when `overrideConfiguration` is invalid.
 *  * IINKErrorRuntime when associated part type is not "Raw Content" or block type is not "Math".
 *  * IINKErrorRuntime when associated with an offscreen editor.
 */
- (BOOL)applyAction:(nonnull NSString *)blockId
             action:(nonnull NSString *)action
overrideConfiguration:(nullable IINKParameterSet *)overrideConfiguration
              error:(NSError * _Nullable * _Nullable)error
        NS_SWIFT_NAME(apply(forBlock:action:overrideConfiguration:));

/**
 * Returns the diagnostic info for the given task and the specified block.
 *
 * @param blockId the identifier of the block.
 * @param task the task to diagnose: either `"numerical-computation"` or `"evaluation"`.
 * @param overrideConfiguration the extra configuration used.
 * @param error the recipient for the error description object
 *  * IINKErrorInvalidArgument when `blockId` is invalid.
 *  * IINKErrorInvalidArgument when `task` is invalid.
 *  * IINKErrorInvalidArgument when `overrideConfiguration` is invalid.
 *  * IINKErrorRuntime when associated part type is not "Raw Content" or block type is not "Math".
 *
 * @return a diagnostic error code, `IINKMathDiagnostic.allowed` if none.
 *
 * @since 4.1
 */
- (nullable IINKMathDiagnosticValue*)getDiagnostic:(nonnull NSString *)blockId
                                                   task:(nonnull NSString *)task
                                  overrideConfiguration:(nullable IINKParameterSet *)overrideConfiguration
                                                  error:(NSError * _Nullable * _Nullable)error
                                           NS_SWIFT_NAME(diagnostic(forBlock:task:overrideConfiguration:));

/**
 * Returns the list of variable names that can be evaluated in the specified block.
 * A block with no syntax error can be evaluated when it contains:
 * - a variable definition
 * - a single (multi-occurrence) undefined variable and no equal sign
 * - an equal sign and two undefined variables, with at least one being a single-occurrence
 * Returns an empty list if block cannot be evaluated.
 *
 * Example: a math block containing `"y = x^3 + 2x + 1"` can evaluate: `{ in:"x", out:"y" }`
 *   a math block containing `"2 * y = x - 1"` can evaluate: `{{ in:"x", out:"y" }, { in:"y", out:"x" }}`
 *   a math block containing `"y = 3 * 4"` can evaluate: `{ in:"", out:"y" }`
 *   a math block containing `"sin(x) + x/2"` can evaluate: `{ in:"x", out:"" }`
 *
 * @note in case both variables can be evaluated interchangeably, the first returned `IINKMathEvaluationVariables`
 *   will use the (leftmost) isolated variable as output if any.
 *   Example: `"y = cos(x) + 1"` will always return: `{{ in:"x", out:"y" }, { in:"y", out:"x" }}` in that order.
 *
 * @param blockId the identifier of the block.
 * @param error the recipient for the error description object
 *  * IINKErrorInvalidArgument when `blockId` is invalid.
 *  * IINKErrorRuntime when associated part type is not "Raw Content" or block type is not "Math".
 *
 * @return a list of IINKMathEvaluationVariables that can be evaluated.
 *
 * @since 4.1
 */
- (nullable NSArray<IINKMathEvaluationVariables *> *)getEvaluables:(nonnull NSString *)blockId
                                                         error:(NSError * _Nullable * _Nullable)error
                                                   NS_SWIFT_NAME(evaluables(forBlock:));

/**
 * Returns the list of points resulting from evaluating the given variables
 * in the specified block.
 *
 * Example: for `"y = 2x"`, `evaluate(blockId, { in:"x", out:"y" }, -1, 1, 3)`
 *   returns `{ {-1, -2}, {0, 0}, {1, 2} }`
 *
 * @param blockId the identifier of the block.
 * @param variables the variables to evaluate.
 * @param from the start of the range to evaluate.
 * @param to the end of the range to evaluate.
 * @param pointCount the number of values to evaluate between `from` and `to`.
 * @param overrideConfiguration the extra configuration used.
 * @param error the recipient for the error description object
 *  * IINKErrorInvalidArgument when `blockId` is invalid.
 *  * IINKErrorInvalidArgument when `variables` are not evaluables.
 *  * IINKErrorInvalidArgument when `from` or `to` is not a number.
 *  * IINKErrorInvalidArgument when `from` is greater than `to`.
 *  * IINKErrorInvalidArgument when `pointCount` is not in `1..10000`.
 *  * IINKErrorInvalidArgument when `overrideConfiguration` is invalid.
 *  * IINKErrorRuntime when associated part type is not "Raw Content" or block type is not "Math".
 *
 * @return a list of evaluated points, representing continuous parts of a curve.
 *   With `point.x` being the input value and `point.y` the evaluated variable output (array of array of NSValue holding CGPoint).
 *
 * @since 4.1
 */
- (nullable NSArray<NSArray<NSValue *> *> *)evaluate:(nonnull NSString *)blockId
                                           variables:(nonnull IINKMathEvaluationVariables *)variables
                                                from:(double)from
                                                  to:(double)to
                                          pointCount:(int)pointCount
                               overrideConfiguration:(nullable IINKParameterSet *)overrideConfiguration
                                               error:(NSError * _Nullable * _Nullable)error
                                         NS_SWIFT_NAME(evaluate(forBlock:variables:from:to:pointCount:overrideConfiguration:));

/**
 * Checks if the specified block represents a variable definition and returns
 * the associated information.
 * A block represents a variable definition if it is an equation with a
 * single variable on the left of the equal sign and a constant expression
 * on the right.
 * Example: `"a = 1/2"`
 *
 * @param blockId the identifier of the block.
 * @param error the recipient for the error description object
 *  * IINKErrorInvalidArgument when `blockId` is invalid.
 *  * IINKErrorRuntime when associated part type is not "Raw Content" or block type is not "Math".
 *
 * @return the name and value of the defined variable if any, otherwise an object which `valid()` method returns `NO`.
 *
 * @since 4.1
 */
- (nullable IINKMathVariableDefinition*)asVariableDefinition:(nonnull NSString *)blockId
                                                       error:(NSError * _Nullable * _Nullable)error
                                                 NS_SWIFT_NAME(variableDefinition(forBlock:));

/**
 * Returns the list of all variable definitions.
 *
 * @param error the recipient for the error description object
 *  * IINKErrorRuntime when associated part type is not "Raw Content" or block type is not "Math".
 *
 * @return the list of all variable definitions.
 *
 * @since 4.2
 */
- (nullable NSArray<IINKMathVariableDefinitions *> *)getVariableDefinitions:(NSError * _Nullable * _Nullable)error
                                                        NS_SWIFT_NAME(variableDefinitions());

/**
 * Retrieves information about defined variables, associated with the specified block or from global variables.
 *
 * @param blockId the identifier of the block whose variables are to be retrieved, or empty for global variables.
 * @param error the recipient for the error description object
 *  * IINKErrorInvalidArgument when `blockId` is invalid.
 *  * IINKErrorRuntime when associated part type is not "Raw Content" or block type is not "Math".
 *
 * @return a vector containing the information of all variables.
 *
 * @since 4.1
 */
- (nullable NSArray<IINKMathVariableInfo *> *)getVariables:(nonnull NSString *)blockId
                                                     error:(NSError * _Nullable * _Nullable)error
                                                NS_SWIFT_NAME(variables(forBlock:));

/**
 * Returns the value associated with the given variable name, for the specified block or as global variable.
 *
 * @param blockId the identifier of the block, or empty for global variable.
 * @param name the variable name.
 * @param error the recipient for the error description object
 *  * IINKErrorInvalidArgument when `blockId` is invalid.
 *  * IINKErrorInvalidArgument if `name` is not an existing variable name.
 *  * IINKErrorRuntime when associated part type is not "Raw Content" or block type is not "Math".
 *
 * @return a variable value.
 *
 * @since 4.1
 */
- (nullable IINKDoubleValue*)getVariableValue:(nonnull NSString *)blockId
                                         name:(nonnull NSString *)name
                                        error:(NSError * _Nullable * _Nullable)error
                                  NS_SWIFT_NAME(getVariableValue(forBlock:name:));

/**
 * Sets the value associated with the given variable name, for the specified block or as global variable.
 *
 * @note `IINKMathVariableSourceTypeAPI` variables have priority over `IINKMathVariableSourceTypeBlock` variables, which have priority over `IINKMathVariableSourceTypeAPIGlobal` variables.
 *   `IINKMathVariableSourceTypePredefined` variables cannot be redefined.
 *
 * @param blockId the identifier of the block, or empty for global variable.
 * @param name the variable name.
 * @param value the variable value.
 * @param error the recipient for the error description object
 *  * IINKErrorInvalidArgument when `blockId` is invalid.
 *  * IINKErrorInvalidArgument when `name` is an invalid variable name.
 *  * IINKErrorInvalidArgument when `value` is an invalid variable value.
 *  * IINKErrorRuntime when associated part type is not "Raw Content" or block type is not "Math".
 *
 * @since 4.1
 */
 - (BOOL)setVariableValue:(nonnull NSString *)blockId
                     name:(nonnull NSString *)name
                    value:(double)value
                    error:(NSError * _Nullable * _Nullable)error
              NS_SWIFT_NAME(setVariableValue(forBlock:name:value:));

/**
 * Removes the definition of the given variable name, for the specified block or as global variable.
 *
 * @param blockId the identifier of the block, or empty for global variable.
 * @param name the variable name.
 * @param error the recipient for the error description object
 *  * IINKErrorInvalidArgument when `blockId` is invalid.
 *  * IINKErrorRuntime when associated part type is not "Raw Content" or block type is not "Math".
 *
 * @return `YES` if the variable existed, otherwise `NO`.
 *
 * @since 4.1
 */
- (BOOL)removeVariableValue:(nonnull NSString *)blockId
                       name:(nonnull NSString *)name
                       error:(NSError * _Nullable * _Nullable)error
                 NS_SWIFT_NAME(removeVariableValue(forBlock:name:));

/**
 * Creates a math external expression from a string, using a copy of `Editor` current configuration.
 *
 * @param expression the math expression to parse.
 * @param mimeType the mime type of the expression. Only `MimeType::LATEX` is currently supported.
 * @param error the recipient for the error description object
 *  * IINKErrorInvalidArgument when `expression` is invalid.
 *  * IINKErrorInvalidArgument when `mimeType` is invalid.
 *
 * @return a math external expression.
 *
 * @since 4.2
 */
- (nullable IINKMathExternalExpression *)parseExternalExpression:(nonnull NSString *)expression
                                    mimeType:(IINKMimeType)mimeType
                                       error:(NSError * _Nullable * _Nullable)error
                                 NS_SWIFT_NAME(parse(expression:mimeType:));

@end
