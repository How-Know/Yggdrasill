// Copyright @ MyScript. All rights reserved.

#import <Foundation/Foundation.h>


/**
 * Allows to access the glyphs (i.e. grapheme clusters) within a label.
 *
 * @note what is called glyph here, is actually a grapheme cluster. For more
 *   details refer to http://unicode.org/reports/tr29/
 */
@interface IINKText : NSObject
{

}

//==============================================================================
#pragma mark - Properties
//==============================================================================

/**
 * The label of this text.
 */
@property (nonatomic, readonly) NSString * _Nonnull label;

/**
 * The number of glyphs associated with this text.
 */
@property (nonatomic, readonly) NSInteger glyphCount;


//==============================================================================
#pragma mark - Glyph Extraction
//==============================================================================

/**
 * Returns the label of a glyph.
 *
 * @param index the index of the glyph.
 * @param error the recipient for the error description object
 *   * IINKInvalidArgument when `index < 0` or `index >= getGlyphCount()`.
 * @return the label of the glyph at `index` on success, otherwise `nil`.
 */
- (NSString * _Nullable)getGlyphLabelAt:(NSInteger)index
                              error:(NSError * _Nullable * _Nullable)error;

/**
 * Returns the starting position of a glyph in the UTF-8 representation of the
 * label of this text.
 *
 * @param index the index of the glyph.
 * @param error the recipient for the error description object
 *   * IINKInvalidArgument when `index < 0` or `index >= getGlyphCount()`.
 * @return the index of the first `char` of the glyph at `index` on success,
 *   otherwise `-1`.
 */
- (int)getGlyphUtf8BeginAt:(NSInteger)index
                 error:(NSError * _Nullable * _Nullable)error;

/**
 * Returns the ending position of a glyph in the UTF-8 representation of the
 * label of this text.
 *
 * @param index the index of the glyph.
 * @param error the recipient for the error description object
 *   * IINKInvalidArgument when `index < 0` or `index >= getGlyphCount()`.
 * @return the index after the last `char` of the glyph at `index` on success,
 *   otherwise `-1`.
 */
- (int)getGlyphUtf8EndAt:(NSInteger)index
               error:(NSError * _Nullable * _Nullable)error;

/**
 * Returns the starting position of a glyph in the UTF-16 representation of
 * the label of this text.
 *
 * @param index the index of the glyph.
 * @param error the recipient for the error description object
 *   * IINKInvalidArgument when `index < 0` or `index >= getGlyphCount()`.
 * @return the index of the first `char16_t` of the glyph at `index` on success,
 *   otherwise `-1`.
 */
- (int)getGlyphUtf16BeginAt:(NSInteger)index
                  error:(NSError * _Nullable * _Nullable)error;

/**
 * Returns the ending position of a glyph in the UTF-16 representation of the
 * label of this text.
 *
 * @param index the index of the glyph.
 * @param error the recipient for the error description object
 *   * IINKInvalidArgument when `index < 0` or `index >= getGlyphCount()`.
 * @return the index after the last `char16_t` of the glyph at `index` on success,
 *   otherwise `-1`.
 */
- (int)getGlyphUtf16EndAt:(NSInteger)index
                error:(NSError * _Nullable * _Nullable)error;

@end
