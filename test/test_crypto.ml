(*---------------------------------------------------------------------------
   Copyright (c) 2020 The brr programmers. All rights reserved.
   Distributed under the ISC license, see terms at the end of the file.
  ---------------------------------------------------------------------------*)

open Brr
open Brr_webcrypto
open Fut.Result_syntax

let data = Jstr.v "Brr it's cold out there."

(* Random values test *)

let test_random log =
  let t = Tarray.create Tarray.Uint8 10 in
  let to_hex t = Tarray.to_hex_jstr ~sep:Jstr.sp t in
  log (El.[txt' "New array: "; code [txt (to_hex t)]]);
  Crypto.set_random_values Crypto.crypto t;
  log (El.[txt' "Rand fill: "; code [txt (to_hex t)]]);
  Fut.ok ()

(* Signing test *)

let sign_key_pair s =
  let sig_key_gen =
    let name = Crypto_algo.rsassa_pks1_v1_5 in
    let modulus_length = 2048 in
    let i65537 = [|0x01; 0x0; 0x01|] in
    let public_exponent = Tarray.of_int_array Tarray.Uint8 i65537 in
    let hash = Jstr.v "SHA-256" in
    Crypto_algo.Rsa_hashed_key_gen_params.v
      ~name ~modulus_length ~public_exponent ~hash ()
  in
  let usages = Crypto_key.Usage.[sign; verify] in
  Subtle_crypto.generate_key_pair s sig_key_gen ~extractable:false ~usages

let sign_algo = Crypto_algo.v Crypto_algo.rsassa_pks1_v1_5
let sign s priv_key d = Subtle_crypto.sign s sign_algo priv_key d
let verify s pub_key sig' d = Subtle_crypto.verify s sign_algo pub_key ~sig' d
let test_signing log =
  let d = Tarray.of_jstr data in
  let s = Crypto.subtle Crypto.crypto in
  let* k = sign_key_pair s in
  let* sig' = sign s (Crypto_key.private' k) d in
  let  sig' = Tarray.uint8_of_buffer sig' in
  let* verif = verify s (Crypto_key.public k) sig' d in
  let to_hex t = Tarray.to_hex_jstr ~sep:Jstr.sp t in
  log El.[txt' "Signed: "; code [txt data]];
  log El.[txt' "Signature: "; pre [txt (to_hex sig')]];
  log El.[txt' "Verification: "; txt' (if verif then "success" else "FAILURE")];
  Console.(assert' verif [str "Signature verification failed"]);
  Fut.ok ()

(* Symmetric encryption test *)

let sym_key s =
  let sym_key_gen =
    let name = Crypto_algo.aes_cbc and length = 128 in
    Crypto_algo.Aes_key_gen_params.v ~name ~length ()
  in
  let usages = Crypto_key.Usage.[encrypt; decrypt] in
  Subtle_crypto.generate_key s sym_key_gen ~extractable:false ~usages

let sym_algo =
  let iv = Tarray.create Tarray.Uint8 16 in
  let () = Crypto.set_random_values Crypto.crypto iv in
  Crypto_algo.Aes_cbc_params.v ~iv:(Tarray.buffer iv) ()

let sym_encrypt s key clear = Subtle_crypto.encrypt s sym_algo key clear
let sym_decrypt s key cipher = Subtle_crypto.decrypt s sym_algo key cipher
let test_sym_crypt log =
  let clear = Tarray.of_jstr data in
  let s = Crypto.subtle Crypto.crypto in
  let* k = sym_key s in
  let* cipher = sym_encrypt s k clear in
  let  cipher = Tarray.uint8_of_buffer cipher in
  let* clear' = sym_decrypt s k cipher in
  let* clear' = Fut.return Tarray.(to_jstr (uint8_of_buffer clear')) in
  let to_hex t = Tarray.to_hex_jstr ~sep:Jstr.sp t in
  log El.[txt' "Clear text: "; code [txt data]];
  log El.[txt' "Cipher text: "; code [txt (to_hex cipher)]];
  log El.[txt' "Decrypted cipher: "; code [txt clear']];
  Console.(assert' (Jstr.equal clear' data) [str "Encryption trip failed"]);
  Fut.ok ()

(* Test *)

let test log =
  Fut.map (Console.log_if_error ~use:()) @@
  let* () = test_random log in
  let* () = test_signing log in
  let* () = test_sym_crypt log in
  Fut.ok ()

let main () =
  let h1 = El.h1 [El.txt' "Web Crypto test"] in
  let log_view = El.ol [] in
  let log cs = El.append_children log_view [El.li cs] in
  let children = [h1; log_view] in
  El.set_children (Document.body G.document) children;
  test log

let () = ignore (main ())

(*---------------------------------------------------------------------------
   Copyright (c) 2020 The brr programmers

   Permission to use, copy, modify, and/or distribute this software for any
   purpose with or without fee is hereby granted, provided that the above
   copyright notice and this permission notice appear in all copies.

   THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
   WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
   MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
   ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
   WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
   ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
   OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
  ---------------------------------------------------------------------------*)
