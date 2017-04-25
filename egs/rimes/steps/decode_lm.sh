#!/bin/bash
set -e;
export LC_NUMERIC=C;
export LUA_PATH="$(pwd)/../../?/init.lua;$(pwd)/../../?.lua;$LUA_PATH";

# Directory where the prepare.sh script is placed.
SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)";
[ "$(pwd)/steps" != "$SDIR" ] && \
    echo "Please, run this script from the experiment top directory!" >&2 && \
    exit 1;
[ ! -f "$(pwd)/utils/parse_options.inc.sh" ] && \
    echo "Missing $(pwd)/utils/parse_options.inc.sh file!" >&2 && exit 1;

acoustic_scale=1.9;
batch_size=16;
beam=65;
word_order=4;
prior_scale=0.2;
voc_size=10000;
height=128;
overwrite=false;
help_message="
Usage: ${0##*/} [options] model

Options:
  --height      : (type = integer, default = $height)
                  Use images rescaled to this height.
  --overwrite   : (type = boolean, default = $overwrite)
                  Overwrite previously created files.
";
source utils/parse_options.inc.sh || exit 1;
[ $# -ne 1 ] && echo "$help_message" >&2 && exit 1;
model="$1";
model_name="$(basename "$1" .t7)";

# Check required files
for f in  "data/lists/te_h$height.lst" \
          "data/lists/tr_h$height.lst" \
	  "data/lists/va_h$height.lst" \
	  "data/lang/lines/char/tr.txt" \
  	  "data/lang/forms/char/te.txt" \
	  "data/lang/forms/char/va.txt" \
	  "data/lang/forms/word/te.txt" \
	  "data/lang/forms/word/va.txt" \
          "train/syms.txt" \
          "$model"; do
  [ ! -s "$f" ] && echo "ERROR: File \"$f\" was not found!" >&2 && exit 1;
done;

hasR=0;
if which Rscript &> /dev/null; then hasR=1; fi;
hasComputeWer=0;
if which compute-wer &> /dev/null; then hasComputeWer=1; fi;

[ $hasR -ne 0 -o $hasComputeWer -ne 0 ] ||
echo "WARNING: Neither Rscript or compute-wer were found, so CER/WER won't be computed!" >&2;

mkdir -p decode/lm/{char,word} decode/lkh/{lines,forms};

# Compute label priors
: <<EOF

priors="$(dirname "$model")/${model_name}.prior";
[ "$overwrite" = false -a -s "$priors" ] ||
../../laia-force-align \
  --batch_size "$batch_size" \
  "$model" "train/syms.txt" \
  "data/lists/tr_h$height.lst" \
  "data/lang/lines/char/tr.txt" \
  /dev/null "$priors";

# Compute log-likelihoods from the network.
for p in va te; do
  lines_ark="decode/lkh/lines/${p}_${model_name}_ps${prior_scale}.ark";
  forms_ark="decode/lkh/forms/${p}_${model_name}_ps${prior_scale}.ark";
  # LINE log-likelihoods
  [ "$overwrite" = false -a -s "$lines_ark" ] ||
  ../../laia-netout \
    --batch_size "$batch_size" \
    --prior "$priors" \
    --prior_alpha "$prior_scale" \
    "$model" "data/lists/${p}_h$height.lst" \
    /dev/stdout |
  copy-matrix ark:- "ark:$lines_ark";
  # FORM log-likelihoods
  [ "$overwrite" = false -a -s "$forms_ark" ] ||
  ./utils/join_lines_arks.sh --add_wspace_border true \
    "train/syms.txt" "$lines_ark" "$forms_ark";
done;

# Build lexicon from the boundaries file.
lexiconp=data/lang/forms/word/lexiconp.txt;
[ "$overwrite" = false -a -s "$lexiconp" ] ||
./utils/prepare_word_lexicon_from_boundaries.sh \
  data/lang/forms/word/tr_boundaries.txt > "$lexiconp" ||
{ echo "ERROR: Creating file \"$lexiconp\"!" >&2 && exit 1; }

# Build word-level language model WITHOUT the unknown token
./utils/build_word_lm.sh --order "$word_order" --voc_size "$voc_size" \
  --unknown false --srilm_options "-kndiscount -interpolate" \
  --overwrite "$overwrite" \
  data/lang/forms/word/tr_{tokenized,boundaries}.txt \
  data/lang/forms/word/va_{tokenized,boundaries}.txt \
  data/lang/forms/word/te_{tokenized,boundaries}.txt \
  decode/lm/word_lm;

# Build decoding FSTs for the word-level language model
./utils/build_word_fsts.sh \
  train/syms.txt data/lang/forms/word/lexiconp.txt \
  "decode/lm/word_lm/tr_tokenized-${word_order}gram-${voc_size}.arpa.gz" \
  "decode/lm/word_fst-${word_order}gram-${voc_size}";


EOF

tmpf="$(mktemp)";
for p in te; do
  forms_ark="decode/lkh/forms/${p}_${model_name}_ps${prior_scale}.ark";
  forms_char="decode/lm/char/${p}_${model_name}.txt";
  forms_word="decode/lm/word/${p}_${model_name}.txt";
  # Obtain char-level transcript for the forms.
  # The character sequence is produced by going through the HMM sequences and then
  # removing some of the dummy HMM boundaries.
  [ "$overwrite" = false -a -s "$forms_char" ] ||
  decode-lazylm-faster-mapped --acoustic-scale="$acoustic_scale" --beam="$beam" \
  "decode/lm/word_fst-${word_order}gram-${voc_size}/model" \
  "decode/lm/word_fst-${word_order}gram-${voc_size}/"{HCL,G}.fst \
  "ark:$forms_ark" ark:/dev/null ark:- |
  ali-to-phones "decode/lm/word_fst-${word_order}gram-${voc_size}/model" ark:- ark,t:- |
  ./utils/int2sym.pl -f 2- "decode/lm/word_fst-${word_order}gram-${voc_size}/chars.txt" |
  ./steps/remove_transcript_dummy_boundaries.sh > "$forms_char";
  # Obtain the word-level transcript for the forms.
  # We just put together all characters that are not <space> to form words.
  [ "$overwrite" = false -a -s "$forms_word" ] ||
  ./steps/remove_transcript_dummy_boundaries.sh --to-words "$forms_char" > "$forms_word";
  if [ $hasR -eq 1 ]; then
    # Compute CER and WER with Confidence Intervals using R
    ./utils/compute-errors.py "data/lang/forms/char/${p}.txt" "$forms_char" > "$tmpf";
    ./utils/compute-confidence.R "$tmpf" |
    awk -v p="$p" '$1 == "%ERR"{ printf("%CER forms %s: %.2f %s %s %s\n", p, $2, $3, $4, $5); }';
    ./utils/compute-errors.py "data/lang/forms/word/${p}.txt" "$forms_word" > "$tmpf";
    ./utils/compute-confidence.R "$tmpf" |
    awk -v p="$p" '$1 == "%ERR"{ printf("%WER forms %s: %.2f %s %s %s\n", p, $2, $3, $4, $5); }';
  elif [ $hasComputeWer -eq 1 ]; then
    # Compute CER and WER using Kaldi's compute-wer
    compute-wer --text --mode=strict \
      "ark:data/lang/forms/char/${p}.txt" "ark:$lines_char" \
      2>/dev/null |
    awk -v p="$p" '$1 == "%WER"{ printf("%CER forms %s: %.2f\n", p, $2); }';
    compute-wer --text --mode=strict \
      "ark:data/lang/forms/word/${p}.txt" "ark:$lines_word" \
      2>/dev/null |
    awk -v p="$p" '$1 == "%WER"{ printf("%WER forms %s: %.2f\n", p, $2); }';
  fi;
done;
rm -f "$tmpf";
