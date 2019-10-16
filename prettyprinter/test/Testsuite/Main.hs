{-# LANGUAGE CPP               #-}
{-# LANGUAGE OverloadedStrings #-}

#include "version-compatibility-macros.h"

module Main (main) where



import           Control.Exception     (evaluate)
import qualified Data.ByteString.Lazy  as BSL
import qualified Data.Text             as T
import           Data.Text.PgpWordlist
import           Data.Word
import           System.Timeout        (timeout)

import Data.Text.Prettyprint.Doc
import Data.Text.Prettyprint.Doc.Render.Text

import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck

import StripTrailingSpace

#if !(APPLICATIVE_MONAD)
import Control.Applicative
#endif
#if !(MONOID_IN_PRELUDE)
import Data.Monoid (mconcat)
#endif



main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "Tests"
    [ testGroup "Fusion"
        [ testProperty "Shallow fusion does not change rendering"
                       (fusionDoesNotChangeRendering Shallow)
        , testProperty "Deep fusion does not change rendering"
                       (fusionDoesNotChangeRendering Deep)
        ]
    , testStripTrailingSpace
    , testGroup "Performance tests"
        [ testCase "Grouping performance"
                   groupingPerformance
        , testCase "fillSep performance"
                   fillSepPerformance
        ]
    , testGroup "Regression tests"
        [ testCase "layoutSmart: softline behaves like a newline (#49)"
                   regressionLayoutSmartSoftline
        , testCase "alterAnnotationsS causes panic when removing annotations (#50)"
                   regressionAlterAnnotationsS
        , testGroup "removeTrailingWhitespace removes leading whitespace (#84)"
            [ testCase "1" regressionRemoveTrailingWhitespace1
            , testCase "2" regressionRemoveTrailingWhitespace2
            , testCase "3" regressionRemoveTrailingWhitespace3
            ]
        , testGroup "removeTrailingWhitespace removes trailing line breaks (#86)"
            [ testCase "1" regressionRemoveTrailingWhiteSpaceTrailingLineBreaks1
            , testCase "2" regressionRemoveTrailingWhiteSpaceTrailingLineBreaks2
            , testCase "3" regressionRemoveTrailingWhiteSpaceTrailingLineBreaks3
            ]
        ]
    ]

fusionDoesNotChangeRendering :: FusionDepth -> Property
fusionDoesNotChangeRendering depth
  = forAll document (\doc ->
        let rendered = render doc
            renderedFused = render (fuse depth doc)
        in counterexample (mkCounterexample rendered renderedFused)
                          (render doc == render (fuse depth doc)) )
  where
    render = renderStrict . layoutPretty defaultLayoutOptions
    mkCounterexample rendered renderedFused
      = (T.unpack . render . vsep)
            [ "Unfused and fused documents render differently!"
            , "Unfused:"
            , indent 4 (pretty rendered)
            , "Fused:"
            , indent 4 (pretty renderedFused) ]

newtype RandomDoc ann = RandomDoc (Doc ann)

instance Arbitrary (RandomDoc ann) where
    arbitrary = fmap RandomDoc document

document :: Gen (Doc ann)
document = (dampen . frequency)
    [ (20, content)
    , (1, newlines)
    , (1, nestingAndAlignment)
    , (1, grouping)
    , (20, concatenationOfTwo)
    , (5, concatenationOfMany)
    , (1, enclosingOfOne)
    , (1, enclosingOfMany) ]

content :: Gen (Doc ann)
content = frequency
    [ (1, pure emptyDoc)
    , (10, do word <- choose (minBound, maxBound :: Word8)
              let pgp8Word = toText (BSL.singleton word)
              pure (pretty pgp8Word) )
    , (1, (fmap pretty . elements . mconcat)
              [ ['a'..'z']
              , ['A'..'Z']
              , ['0'..'9']
              , "…_[]^!<>=&@:-()?*}{/\\#$|~`+%\"';" ] )
    ]

newlines :: Gen (Doc ann)
newlines = frequency
    [ (1, pure line)
    , (1, pure line')
    , (1, pure softline)
    , (1, pure softline')
    , (1, pure hardline) ]

nestingAndAlignment :: Gen (Doc ann)
nestingAndAlignment = frequency
    [ (1, nest   <$> arbitrary <*> concatenationOfMany)
    , (1, group  <$> document)
    , (1, hang   <$> arbitrary <*> concatenationOfMany)
    , (1, indent <$> arbitrary <*> concatenationOfMany) ]

grouping :: Gen (Doc ann)
grouping = frequency
    [ (1, align  <$> document)
    , (1, flatAlt <$> document <*> document) ]

concatenationOfTwo :: Gen (Doc ann)
concatenationOfTwo = frequency
    [ (1, (<>) <$> document <*> document)
    , (1, (<+>) <$> document <*> document) ]

concatenationOfMany :: Gen (Doc ann)
concatenationOfMany = frequency
    [ (1, hsep    <$> listOf document)
    , (1, vsep    <$> listOf document)
    , (1, fillSep <$> listOf document)
    , (1, sep     <$> listOf document)
    , (1, hcat    <$> listOf document)
    , (1, vcat    <$> listOf document)
    , (1, fillCat <$> listOf document)
    , (1, cat     <$> listOf document) ]

enclosingOfOne :: Gen (Doc ann)
enclosingOfOne = frequency
    [ (1, squotes  <$> document)
    , (1, dquotes  <$> document)
    , (1, parens   <$> document)
    , (1, angles   <$> document)
    , (1, brackets <$> document)
    , (1, braces   <$> document) ]

enclosingOfMany :: Gen (Doc ann)
enclosingOfMany = frequency
    [ (1, encloseSep <$> document <*> document <*> pure ", " <*> listOf document)
    , (1, list       <$> listOf document)
    , (1, tupled     <$> listOf document) ]

-- QuickCheck 2.8 does not have 'scale' yet, so for compatibility with older
-- releases we hand-code it here
dampen :: Gen a -> Gen a
dampen gen = sized (\n -> resize ((n*2) `quot` 3) gen)

docPerformanceTest :: Doc ann -> Assertion
docPerformanceTest doc
  = timeout 10000000 (forceDoc doc) >>= \doc' -> case doc' of
    Nothing -> assertFailure "Timeout!"
    Just _success -> pure ()
  where
    forceDoc :: Doc ann -> IO ()
    forceDoc = evaluate . foldr seq () . show

-- Deeply nested group/flatten calls can result in exponential performance.
--
-- See https://github.com/quchen/prettyprinter/issues/22
groupingPerformance :: Assertion
groupingPerformance = docPerformanceTest (pathological 1000)
  where
    pathological :: Int -> Doc ann
    pathological n = iterate (\x ->  hsep [x, sep []] ) "foobar" !! n

-- This test case was written because the `pretty` package had an issue with
-- this specific example.
--
-- See https://github.com/haskell/pretty/issues/32
fillSepPerformance :: Assertion
fillSepPerformance = docPerformanceTest (pathological 1000)
  where
    pathological :: Int -> Doc ann
    pathological n = iterate (\x -> fillSep ["a", x <+> "b"] ) "foobar" !! n

regressionLayoutSmartSoftline :: Assertion
regressionLayoutSmartSoftline
  = let doc = "a" <> softline <> "b"
        layouted :: SimpleDocStream ()
        layouted = layoutSmart (defaultLayoutOptions { layoutPageWidth = Unbounded }) doc
    in assertEqual "softline should be rendered as space page width is unbounded"
                   (SChar 'a' (SChar ' ' (SChar 'b' SEmpty)))
                   layouted

-- Removing annotations with alterAnnotationsS used to remove pushes, but not
-- pops, leading to imbalanced SimpleDocStreams.
regressionAlterAnnotationsS :: Assertion
regressionAlterAnnotationsS
  = let sdoc, sdoc' :: SimpleDocStream Int
        sdoc = layoutSmart defaultLayoutOptions (annotate 1 (annotate 2 (annotate 3 "a")))
        sdoc' = alterAnnotationsS (\ann -> case ann of 2 -> Just 2; _ -> Nothing) sdoc
    in assertEqual "" (SAnnPush 2 (SChar 'a' (SAnnPop SEmpty))) sdoc'

regressionRemoveTrailingWhitespace1 :: Assertion
regressionRemoveTrailingWhitespace1
  = let sdoc :: SimpleDocStream ()
        sdoc = SLine 0 (SText 2 "  " (SChar 'x' SEmpty))
    in assertEqual "" sdoc (removeTrailingWhitespace sdoc)

regressionRemoveTrailingWhitespace2 :: Assertion
regressionRemoveTrailingWhitespace2
  = let sdoc :: SimpleDocStream ()
        sdoc = SLine 0 (SChar ' ' (SChar 'x' SEmpty))
    in assertEqual "" sdoc (removeTrailingWhitespace sdoc)

regressionRemoveTrailingWhitespace3 :: Assertion
regressionRemoveTrailingWhitespace3
  = let sdoc :: SimpleDocStream ()
        sdoc = SLine 0 (SChar ' ' (SText 2 "  " (SChar 'x' SEmpty)))
        sdoc' = SLine 0 (SText 3 "   " (SChar 'x' SEmpty))
    in assertEqual "" sdoc' (removeTrailingWhitespace sdoc)

regressionRemoveTrailingWhiteSpaceTrailingLineBreaks1 :: Assertion
regressionRemoveTrailingWhiteSpaceTrailingLineBreaks1
  = let sdoc :: SimpleDocStream ()
        sdoc = SLine 0 SEmpty
    in assertEqual "" sdoc (removeTrailingWhitespace sdoc)

regressionRemoveTrailingWhiteSpaceTrailingLineBreaks2 :: Assertion
regressionRemoveTrailingWhiteSpaceTrailingLineBreaks2
  = let sdoc :: SimpleDocStream ()
        sdoc = SChar 'x' (SLine 0 SEmpty)
    in assertEqual "" sdoc (removeTrailingWhitespace sdoc)

regressionRemoveTrailingWhiteSpaceTrailingLineBreaks3 :: Assertion
regressionRemoveTrailingWhiteSpaceTrailingLineBreaks3
  = let sdoc :: SimpleDocStream ()
        sdoc = SChar 'x' (SLine 2 (SText 2 "  " SEmpty))
        sdoc' = SChar 'x' (SLine 0 SEmpty)
    in assertEqual "" sdoc' (removeTrailingWhitespace sdoc)
