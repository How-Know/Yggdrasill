// Copyright @ MyScript. All rights reserved.

#import <Foundation/Foundation.h>
#import <iink/IINKMathSolverController.h>


//==============================================================================
// MathSolverController
//==============================================================================

/**
 * The MathExternalExpression allows to manage an external math expression.
 *
 * @since 4.2
 */
@interface IINKMathExternalExpression : NSObject
{

}

//==============================================================================
#pragma mark - Properties
//==============================================================================

/**
 * The expression original string.
 */
@property (nonatomic, readonly, nonnull) NSString *expression;

/**
 * The list of variable names that can be evaluated.
 * An expression with no syntax error can be evaluated when it contains:
 * - a variable definition
 * - a single (multi-occurrence) undefined variable and no equal sign
 * - an equal sign and two undefined variables, with at least one being a single-occurrence
 * Returns an empty list if expression cannot be evaluated.
 *
 * Note: in case both variables can be evaluated interchangeably, the first returned `IINKMathEvaluationVariables`
 *   will use the (leftmost) isolated variable as output if any.
 *   Example: `"y = cos(x) + 1"` will always return: `{{ in:"x", out:"y" }, { in:"y", out:"x" }}` in that order.
 **/
@property (nonatomic, readonly, nonnull) NSArray<IINKMathEvaluationVariables *> *evaluables;

/**
 * Checks if expression represents a variable definition and returns the associated information.
 * An expression represents a variable definition if it is an equation with a single variable
 * on the left of the equal sign and at least one constant expression on the right (first value is used).
 * Example: `"a = 1/2"` or `"b = 1/3 = 0.33"`
 */
@property (nonatomic, readonly, nonnull) IINKMathVariableDefinition* variableDefinition;

/**
 * Information about all variables associated with the expression.
 */
@property (nonatomic, readonly, nonnull) NSArray<IINKMathVariableInfo *> *variables;



//==============================================================================
#pragma mark - Methods
//==============================================================================

/**
 * Returns the diagnostic info for the given task.
 *
 * @param task the task to diagnose. Only `"evaluation"` is currently supported.
 * @param overrideConfiguration the extra configuration used.
 * @param error the recipient for the error description object
 *  * IINKErrorInvalidArgument when `task` is invalid.
 *  * IINKErrorInvalidArgument when `overrideConfiguration` is invalid.
 *
 * @return a diagnostic code.
 */
- (nullable IINKMathDiagnosticValue *)getDiagnostic:(nonnull NSString *)task
                              overrideConfiguration:(nullable IINKParameterSet *)overrideConfiguration
                                              error:(NSError * _Nullable * _Nullable)error
                                      NS_SWIFT_NAME(diagnostic(forTask:overrideConfiguration:));


/**
 * Returns the list of points resulting from evaluating the given variables.
 *
 * Example: for `"y = 2x"`, `evaluate(blockId, { in:"x", out:"y" }, -1, 1, 3)`
 *   returns `{ {-1, -2}, {0, 0}, {1, 2} }`
 *
 * @param variables the variables to evaluate.
 * @param from the start of the range to evaluate.
 * @param to the end of the range to evaluate.
 * @param pointCount the number of values to evaluate between `from` and `to`.
 * @param overrideConfiguration the extra configuration used.
 * @param error the recipient for the error description object
 *  * IINKErrorInvalidArgument when `variables` are not evaluables.
 *  * IINKErrorInvalidArgument when `from` or `to` is not a number.
 *  * IINKErrorInvalidArgument when `from` is greater than `to`.
 *  * IINKErrorInvalidArgument when `pointCount` is not in `1..10000`.
 *  * IINKErrorInvalidArgument when `overrideConfiguration` is invalid.
 *
 * @return a list of evaluated points, representing continuous parts of a curve.
 *   With `point.x` being the input value and `point.y` the evaluated variable output (array of array of NSValue holding CGPoint).
 */
- (nullable NSArray<NSArray<NSValue *> *> *)evaluate:(nonnull IINKMathEvaluationVariables *)variables
                                                from:(double)from
                                                  to:(double)to
                                          pointCount:(int)pointCount
                               overrideConfiguration:(nullable IINKParameterSet *)overrideConfiguration
                                               error:(NSError * _Nullable * _Nullable)error
                                         NS_SWIFT_NAME(evaluate(variables:from:to:pointCount:overrideConfiguration:));

/**
 * Returns the value associated with the given variable name.
 *
 * @param name the variable name.
 * @param error the recipient for the error description object
 *  * IINKErrorInvalidArgument if `name` is not an existing variable name.
 *
 * @return a variable value.
 */
- (nullable IINKDoubleValue*)getVariableValue:(nonnull NSString *)name
                                        error:(NSError * _Nullable * _Nullable)error
                                  NS_SWIFT_NAME(getVariableValue(forName:));

/**
 * Sets the value associated with the given variable name.
 *
 * @param name the variable name.
 * @param value the variable value.
 * @param error the recipient for the error description object
 *  * IINKErrorInvalidArgument when `name` is an invalid variable name.
 *  * IINKErrorInvalidArgument when `value` is an invalid variable value.
 */
 - (BOOL)setVariableValue:(nonnull NSString *)name
                    value:(double)value
                    error:(NSError * _Nullable * _Nullable)error
              NS_SWIFT_NAME(setVariableValue(forName:value:));

/**
 * Removes the definition of the given variable name.
 *
 * @param name the variable name.
 * @param error the recipient for the error description object
 *  * IINKErrorInvalidArgument when `name` is an invalid variable name.
 *
 * @return `YES` if the variable existed, otherwise `NO`.
 */
- (BOOL)removeVariableValue:(nonnull NSString *)name
                      error:(NSError * _Nullable * _Nullable)error
                 NS_SWIFT_NAME(removeVariableValue(forName:));

@end
