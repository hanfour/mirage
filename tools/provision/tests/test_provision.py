import os
import tempfile
import unittest
import unittest.mock

import provision


class ExitCodeContractTests(unittest.TestCase):
    def test_unwritable_avd_home_is_exit_2_not_1(self):
        """退出碼 1 的意思是「有漂移」。權限炸掉卻回 1，會讓只看退出碼的
        自動化把「環境壞了」讀成「環境需要修」——而且那時一份報表都還沒印。

        _resolve 被 mock 成空 list，所以這條測試不連網、不下載任何東西。"""
        with tempfile.TemporaryDirectory() as tmp:
            avd_home = os.path.join(tmp, "avd")
            os.makedirs(avd_home)
            os.chmod(avd_home, 0o500)  # r-x：進得去但寫不了
            try:
                with unittest.mock.patch("provision._resolve", return_value=[]):
                    code = provision.main(
                        ["--apply", "--sdk-root", tmp, "--avd-home", avd_home]
                    )
                self.assertEqual(code, 2)
            finally:
                # 不還原權限的話 TemporaryDirectory 清不掉。
                os.chmod(avd_home, 0o700)


if __name__ == "__main__":
    unittest.main()
