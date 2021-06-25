{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE RecordWildCards #-}
module SlideRules.Renderer.FasterSVG where

-- base
import Data.Foldable
import Data.Function ((&))
import Data.Maybe (fromMaybe)
import System.IO

-- bytestring
import Data.ByteString (ByteString)
import Data.ByteString.Builder

-- linear
import Linear.V2

-- text
import qualified Data.Text as T
import qualified Data.Text.Encoding as T

-- local (sliderules)
import SlideRules.Types
import SlideRules.Tick
import SlideRules.Scales
import SlideRules.Renderer

data FasterSVG

instance (Num fl, Show fl, Floating fl, Ord fl) => Renderer FasterSVG fl where
    type Representation FasterSVG fl = Builder
    renderTick _ = tickToElement
    renderTickStatic _ = tickToElementStatic
    renderTicks proxya renderSettings ticks =
        let viewbox = allTicksViewbox renderSettings ticks
            content = foldMap (renderTick proxya renderSettings) ticks
        in
        svg renderSettings viewbox content
    writeRepToFile _ path rep = do
        withFile path WriteMode $ \handle -> do
            hSetBinaryMode handle True
            hSetBuffering handle $ BlockBuffering Nothing
            hPutBuilder handle rep

-- Viewboxes

data Viewbox fl = Viewbox { origin :: Cart fl, dimensions :: Cart fl }
    deriving (Show)

allTicksViewbox :: forall fl f. (Num fl, Ord fl, Floating fl, Foldable f) => RenderSettings fl -> f (Tick fl) -> Viewbox fl
allTicksViewbox RenderSettings{ heightMultiplier, padding } fticks =
    let xBounds, yBounds :: Bounds fl
        (Bounds2D (V2 xBounds yBounds)) =
            foldr (\x acc -> acc <> bounds x) originBounds2D fticks
        originX = lower xBounds
        originY = upper yBounds * heightMultiplier
        origin = cart originX originY - cart padding (negate $ padding)
        dimensionsX = upper xBounds - lower xBounds
        dimensionsY = (lower yBounds - upper yBounds) * heightMultiplier
        dimensions = cart dimensionsX dimensionsY + cart (padding * 2) (negate $ padding * 2)
    in
    Viewbox { origin, dimensions }

dimensionsAttrs :: (Show fl, Num fl, Floating fl) => RenderSettings fl -> Viewbox fl -> Builder
dimensionsAttrs RenderSettings{ xPow, yPow } (Viewbox { origin, dimensions }) =
    fold
        [ attribute "viewBox" (fold [show7 (x origin), " ", show7 (y origin), " ", show7 (x dimensions), " ", show7 (y dimensions)])
        , " "
        , attribute "height" (show7 $ (10 ** fromIntegral yPow) * (y dimensions / x dimensions))
        , " "
        , attribute "width" (show7 $ 10 ** fromIntegral xPow)
        ]

-- Utils
show7 :: Show a => a -> Builder
show7 = string7 . show

newtype Cart fl = Cart (V2 fl)
    deriving (Num, Show)
cart :: fl -> fl -> Cart fl
cart x y = cartV2 (V2 x y)
cartV2 :: V2 fl -> Cart fl
cartV2 = Cart
uncurryC :: Num fl => (fl -> fl -> a) -> Cart fl -> a
uncurryC f cart = f (x cart) (y cart)
x, y :: Num fl => Cart fl -> fl
x (Cart (V2 x _)) = x
y (Cart (V2 _ y)) = negate y

-- Basic SVG utils
svg :: (Show fl, Floating fl) => RenderSettings fl -> Viewbox fl -> Builder -> Builder
svg renderSettings viewbox content = fold
    [ "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
    , "<!DOCTYPE svg PUBLIC \"-//W3C//DTD SVG 1.1//EN\" \"http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd\">"
    , "<svg xmlns:xlink=\"http://www.w3.org/1999/xlink\" version=\"1.11.1\" xmlns=\"http://www.w3.org/2000/svg\" "
    , dimensionsAttrs renderSettings viewbox
    , ">"
    -- , "<rect width=\"1000\" height=\"1000\" fill=\"transparent\"></rect>"
    , content  -- & gTranslate (cart 500 (-500))
    , "</svg>"
    ]

gTransform :: Builder -> Builder -> Builder
gTransform transform children = fold
    [ "<g ", attribute "transform" transform, ">", children, "</g>" ]

gTranslate :: (Show fl, Num fl) => Cart fl -> Builder -> Builder
gTranslate cart = gTransform (fold ["translate(", show7 $ x cart, ",", show7 $ y cart, ")"])

gScale :: Show fl => fl -> Builder -> Builder
gScale factor = gTransform (fold ["scale(", show7 factor, ",", show7 factor, ")"])

gRotate :: (Show fl, Num fl) => fl -> Builder -> Builder
gRotate pct = gTransform (fold ["rotate(", show7 (360 * pct), ")"])

textBdr :: Show fl => Builder -> SimpleAnchor -> fl -> Builder
textBdr t simpleAnchor fontSize = fold
    [ "<text "
    , attribute "font-family" "Comfortaa"
    , " "
    , attribute "font-size" (string7 (show fontSize))
    , " "
    , simpleYToAttr (simpleY simpleAnchor)
    , " "
    , simpleXToAttr (simpleX simpleAnchor)
    , ">"
    , t
    , "</text>"
    ]

textUTF :: Show fl => T.Text -> SimpleAnchor -> fl -> Builder
textUTF t simpleAnchor fontSize =
    textBdr (byteString $ T.encodeUtf8 t) simpleAnchor fontSize

segment :: (Show fl, Num fl) => ByteString -> fl -> Cart fl -> Builder
segment strokeColor strokeWidth cart = fold
    [ "<path ", attribute "stroke-width" (show7 strokeWidth), " ", attribute "d" (fold [ "M 0,0 l ", show7 $ x cart, ",", show7 $ y cart ]), " ", attribute "stroke" (byteString strokeColor), "/>" ]

attribute :: ByteString -> Builder -> Builder
attribute name value = fold
    [ byteString name, "=\"", value, "\"" ]

-- SVG anchors

data SimpleAnchorX = Start | Middle | End
data SimpleAnchorY = Bottom | Center | Top
data SimpleAnchor = SimpleAnchor { simpleX :: SimpleAnchorX, simpleY :: SimpleAnchorY }

roundSimple :: (Fractional fl, Ord fl) => TextAnchor fl -> SimpleAnchor
roundSimple TextAnchor{..} = SimpleAnchor simpleX simpleY
    where
    simpleX
      | _xPct < 0.25 = Start
      | _xPct > 0.75 = End
      | otherwise = Middle
    simpleY
      | _yPct < 0.25 = Bottom
      | _yPct > 0.75 = Top
      | otherwise = Center

simpleYToAttr :: SimpleAnchorY -> Builder
simpleYToAttr Top    = attribute "dominant-baseline" "text-top"
simpleYToAttr Center = attribute "dominant-baseline" "central"
simpleYToAttr Bottom = attribute "dominant-baseline" "text-bottom"

simpleXToAttr :: SimpleAnchorX -> Builder
simpleXToAttr Start  = attribute "text-anchor" "start"
simpleXToAttr Middle = attribute "text-anchor" "middle"
simpleXToAttr End    = attribute "text-anchor" "end"

-- Converting ticks

tickToElement :: (Num fl, Fractional fl, Ord fl, Show fl) => RenderSettings fl -> Tick fl -> Builder
tickToElement renderSettings@RenderSettings{ heightMultiplier } tick =
    let staticTick = tickToElementStatic renderSettings tick
    in
    case _offset tick of
        Vertical y ->
            staticTick
                & gTranslate (cart (_postPos tick) (y * heightMultiplier))
        Radial rad ->
            error "implement"
        --     staticTick
        --         & D.translate (D.r2 (0, rad))
        --         & D.rotateBy (negate $ realToFrac $ _postPos tick)

tickToElementStatic :: forall fl. (Num fl, Fractional fl, Ord fl, Show fl) => RenderSettings fl -> Tick fl -> Builder
tickToElementStatic RenderSettings{ lineWidth, heightMultiplier, textMultiplier } tick =
    let Tick { _prePos, _postPos, _info } = tick
        TickInfo { _start, _end, _mlabel } = _info
        startV2 = cart 0 (heightMultiplier * _start)
        endV2   = cart 0 (heightMultiplier * _end)
        diffV2  = endV2 - startV2
        tickDia = segment "#FF0000" lineWidth diffV2 & gTranslate startV2
        labelDia = fromMaybe mempty $ do
            Label {..} <- _mlabel
            let labelOffset :: Cart fl
                labelOffset
                  = cartV2 _anchorOffset * cart 1 heightMultiplier
                  + case _tickAnchor of
                      Pct p -> startV2 + diffV2 * cart p p
                      FromTopAbs x -> endV2 + cart 0 (heightMultiplier * x)
                      FromBottomAbs x -> startV2 + cart 0 (heightMultiplier * x)
            let 
            pure $ gTranslate labelOffset $
                textUTF
                    (T.pack _text)
                    (roundSimple _textAnchor)
                    (heightMultiplier * textMultiplier * _fontSize)
     in tickDia <> labelDia
